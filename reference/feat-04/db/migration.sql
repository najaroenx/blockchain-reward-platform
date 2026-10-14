-- =====================================================================
-- FEAT-04 · Create Point Type · migration
-- ร้านประกาศ point ของตัวเอง แล้ว deploy token ผ่าน factory บน chain
--
-- การตัดสินใจหลักของ feature นี้อยู่ที่การแยกสองตาราง
--   point_type        ← คำประกาศของร้าน · เขียนโดย api · rebuild จาก chain ไม่ได้
--   point_type_chain  ← ผลจาก chain · เขียนโดย projector · rebuild ได้เสมอ
-- เหตุผลเต็มอยู่ใน README · กฎที่มาคือ RFD 6 §3.2
--
-- อ้างอิง  RFD 2 §3.3 · RFD 3 D1 · RFD 6 §3.2 · RFD 10 · RFD 14 L3
-- รันบน PostgreSQL 16 ได้ตรงๆ
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------- enum
CREATE TYPE operation_kind AS ENUM (
  'MERCHANT_PROVISION', 'POINT_TYPE_CREATE', 'POINT_TRANSFER',
  'COUPON_TYPE_CREATE', 'COUPON_ISSUE',     'COUPON_REDEEM',
  'LISTING_CREATE',     'LISTING_DELETE',   'LISTING_BUY',
  'THB_MINT'
);

CREATE TYPE operation_status AS ENUM (
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW'
);

CREATE TYPE step_status AS ENUM (
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED'
);

CREATE TYPE merchant_status AS ENUM ('PENDING', 'ACTIVE', 'SUSPENDED', 'CLOSED');

-- สถานะของ point type ในมุมของร้าน ไม่ใช่ของ chain
CREATE TYPE point_type_status AS ENUM (
  'REQUESTED',   -- ร้านประกาศแล้ว · ยังไม่มี contract
  'LIVE',        -- deploy เสร็จ ใช้งานได้
  'FAILED',      -- deploy ล้ม · ชื่อถูกปล่อยคืน
  'RETIRED'      -- เลิกใช้ · ยอดเดิมยังอยู่
);

CREATE TYPE actor_type AS ENUM ('SYSTEM', 'MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

-- ---------------------------------------------------- ตัวตน (จาก FEAT-01)
CREATE TABLE merchant (
  id          text PRIMARY KEY,
  name        text            NOT NULL,
  status      merchant_status NOT NULL DEFAULT 'PENDING',
  created_at  timestamptz     NOT NULL DEFAULT now()
);

CREATE TABLE wallet (
  id          text PRIMARY KEY,
  address     bytea       NOT NULL CHECK (octet_length(address) = 20),
  key_ref     text        NOT NULL,
  owner_kind  text        NOT NULL CHECK (owner_kind IN ('MERCHANT','CUSTOMER','PLATFORM')),
  owner_id    text        NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_wallet_address ON wallet (address);
CREATE UNIQUE INDEX uq_wallet_owner   ON wallet (owner_kind, owner_id);

CREATE TABLE signer (
  address     bytea PRIMARY KEY CHECK (octet_length(address) = 20),
  key_ref     text        NOT NULL,
  next_nonce  bigint      NOT NULL DEFAULT 0 CHECK (next_nonce >= 0),
  enabled     boolean     NOT NULL DEFAULT true
);

-- ================================================= ฝั่งคำประกาศของร้าน
-- ตารางนี้ไม่ใช่ projection · ชื่อและสัญลักษณ์มาจากร้าน ไม่ได้มาจาก chain
-- ลบทิ้งแล้ว replay chain_event ใหม่ จะได้ชื่อกลับมาไม่ได้
CREATE TABLE point_type (
  id            text PRIMARY KEY,
  merchant_id   text              NOT NULL REFERENCES merchant(id),
  name          text              NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 60),
  -- สัญลักษณ์แบบ ERC-20 · ตัวใหญ่ล้วน 2-11 ตัว
  symbol        text              NOT NULL CHECK (symbol ~ '^[A-Z][A-Z0-9]{1,10}$'),
  -- RFD 14 · จำนวนหลักทศนิยมของ token · ใช้แปลงที่ชั้นแสดงผลเท่านั้น
  decimals      smallint          NOT NULL CHECK (decimals BETWEEN 0 AND 30),
  status        point_type_status NOT NULL DEFAULT 'REQUESTED',
  created_at    timestamptz       NOT NULL DEFAULT now(),
  live_at       timestamptz,
  retired_at    timestamptz,
  CONSTRAINT ck_point_type_live
    CHECK ((status = 'LIVE') = (live_at IS NOT NULL) OR status = 'RETIRED'),
  CONSTRAINT ck_point_type_retired
    CHECK ((status = 'RETIRED') = (retired_at IS NOT NULL))
);

-- ชื่อและสัญลักษณ์จองได้ทีละอัน แต่เฉพาะอันที่ยังไม่ล้ม
-- deploy ล้มแล้วชื่อถูกปล่อยคืนให้ใช้ใหม่ได้
CREATE UNIQUE INDEX uq_point_symbol
  ON point_type (merchant_id, symbol) WHERE status <> 'FAILED';
CREATE UNIQUE INDEX uq_point_name
  ON point_type (merchant_id, lower(btrim(name))) WHERE status <> 'FAILED';
CREATE INDEX ix_point_type_merchant ON point_type (merchant_id, status);

-- ======================================================= ฝั่งผลจาก chain
-- ตารางนี้เป็น projection แท้ · ทุกค่า derive จาก chain_event ได้
-- ลบทิ้งทั้งตารางแล้ว replay ใหม่ ต้องได้ค่าเดิมเป๊ะ (RFD 6 §3.2)
CREATE TABLE point_type_chain (
  point_type_id    text PRIMARY KEY REFERENCES point_type(id),
  contract_address bytea         NOT NULL CHECK (octet_length(contract_address) = 20),
  deployed_block   bigint        NOT NULL CHECK (deployed_block > 0),
  deployed_tx_hash bytea         NOT NULL CHECK (octet_length(deployed_tx_hash) = 32),
  -- RFD 10 · ค่าคงที่ของ contract ที่อ่านครั้งเดียวตอน deploy
  -- expires_at ของแต่ละ bucket คำนวณจากสามค่านี้ จึง rebuild ได้เสมอ
  genesis_at       timestamptz   NOT NULL,
  epoch_seconds    integer       NOT NULL CHECK (epoch_seconds > 0),
  validity_epochs  integer       NOT NULL CHECK (validity_epochs > 0),
  applied_at       timestamptz   NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_point_chain_address ON point_type_chain (contract_address);

-- contract address เปลี่ยนไม่ได้หลังถูกเขียน
-- ถ้า deploy ใหม่ ต้องเป็น point_type แถวใหม่ ไม่ใช่แก้แถวเดิม
CREATE OR REPLACE FUNCTION f_point_chain_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contract_address <> OLD.contract_address
     OR NEW.genesis_at    <> OLD.genesis_at
     OR NEW.epoch_seconds <> OLD.epoch_seconds THEN
    RAISE EXCEPTION 'point_type_chain เปลี่ยนค่าที่มาจาก chain ไม่ได้'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_point_chain_immutable
  BEFORE UPDATE ON point_type_chain
  FOR EACH ROW EXECUTE FUNCTION f_point_chain_immutable();

-- ร้านที่ยังไม่ ACTIVE สร้าง point type ไม่ได้
-- บังคับที่ฐานข้อมูล ไม่ใช่แค่ guard ใน api (FEAT-01 §3.4)
CREATE OR REPLACE FUNCTION f_merchant_must_be_active() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s merchant_status;
BEGIN
  SELECT status INTO s FROM merchant WHERE id = NEW.merchant_id;
  IF s <> 'ACTIVE' THEN
    RAISE EXCEPTION 'ร้าน % ยังไม่ ACTIVE (status = %)', NEW.merchant_id, s
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_point_type_merchant_active
  BEFORE INSERT ON point_type
  FOR EACH ROW EXECUTE FUNCTION f_merchant_must_be_active();

-- -------------------------------------------- Group B · แกน write path
CREATE TABLE idempotency_key (
  id              text PRIMARY KEY,
  scope           text        NOT NULL,
  key             text        NOT NULL CHECK (length(key) BETWEEN 8 AND 255),
  fingerprint     bytea       NOT NULL CHECK (octet_length(fingerprint) = 32),
  operation_id    text,
  response_status integer,
  response_body   jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL DEFAULT now() + interval '72 hours'
);
CREATE UNIQUE INDEX uq_idem ON idempotency_key (scope, key);

CREATE TABLE operation (
  id            text PRIMARY KEY,
  actor_scope   text             NOT NULL,
  kind          operation_kind   NOT NULL,
  status        operation_status NOT NULL DEFAULT 'PENDING',
  subject_id    text,
  payload       jsonb            NOT NULL,
  error_note    text,
  created_at    timestamptz      NOT NULL DEFAULT now(),
  finalized_at  timestamptz,
  CONSTRAINT ck_finalized_consistent
    CHECK ((status = 'FINALIZED') = (finalized_at IS NOT NULL))
);
CREATE INDEX ix_operation_open ON operation (created_at)
  WHERE status NOT IN ('FINALIZED','CHAIN_REVERTED');

-- point type หนึ่งอันมีงาน deploy ค้างได้ทีละงานเดียว
CREATE UNIQUE INDEX uq_point_deploy_inflight
  ON operation (subject_id)
  WHERE kind = 'POINT_TYPE_CREATE'
    AND status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

CREATE TABLE operation_step (
  id              text PRIMARY KEY,
  operation_id    text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  step_index      integer     NOT NULL CHECK (step_index >= 1),
  name            text        NOT NULL,
  signer_address  bytea       REFERENCES signer(address),
  nonce           bigint      CHECK (nonce IS NULL OR nonce >= 0),
  raw_tx          bytea,
  tx_hash         bytea       CHECK (tx_hash IS NULL OR octet_length(tx_hash) = 32),
  status          step_status NOT NULL DEFAULT 'PENDING',
  submitted_at    timestamptz,
  confirmed_at    timestamptz,
  finalized_at    timestamptz,
  CONSTRAINT ck_rawtx_before_broadcast
    CHECK (status = 'PENDING' OR raw_tx IS NOT NULL)
);
CREATE UNIQUE INDEX uq_step_order  ON operation_step (operation_id, step_index);
CREATE UNIQUE INDEX uq_step_txhash ON operation_step (tx_hash) WHERE tx_hash IS NOT NULL;
CREATE UNIQUE INDEX uq_signer_nonce ON operation_step (signer_address, nonce)
  WHERE signer_address IS NOT NULL AND nonce IS NOT NULL;

CREATE TABLE outbox (
  id            text PRIMARY KEY,
  operation_id  text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  topic         text        NOT NULL CHECK (topic ~ '\.v[0-9]+$'),
  payload       jsonb       NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz
);
CREATE INDEX idx_outbox_pending ON outbox (created_at) WHERE sent_at IS NULL;

CREATE TABLE operation_event (
  id            text PRIMARY KEY,
  operation_id  text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  from_status   operation_status,
  to_status     operation_status NOT NULL,
  actor         actor_type  NOT NULL DEFAULT 'SYSTEM',
  tx_hash       bytea,
  metadata      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- --------------------------------------------- Group C · ฝั่งอ่าน chain
CREATE TABLE chain_event (
  id              text PRIMARY KEY,
  block_number    bigint      NOT NULL,
  block_hash      bytea       NOT NULL CHECK (octet_length(block_hash) = 32),
  tx_hash         bytea       NOT NULL CHECK (octet_length(tx_hash) = 32),
  log_index       integer     NOT NULL,
  address         bytea       NOT NULL CHECK (octet_length(address) = 20),
  topic0          bytea       NOT NULL,
  topics          jsonb       NOT NULL DEFAULT '[]'::jsonb,
  data            bytea       NOT NULL,
  block_timestamp timestamptz NOT NULL,
  operation_id    text        REFERENCES operation(id),
  orphaned_at     timestamptz,
  applied_at      timestamptz
);
CREATE UNIQUE INDEX uq_chain_event ON chain_event (tx_hash, log_index);

CREATE TABLE indexer_cursor (
  contract_address bytea PRIMARY KEY CHECK (octet_length(contract_address) = 20),
  last_block       bigint      NOT NULL,
  last_block_hash  bytea,
  updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMIT;
