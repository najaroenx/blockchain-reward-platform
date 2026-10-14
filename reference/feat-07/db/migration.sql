-- =====================================================================
-- FEAT-07 · Create Coupon Type + Issue Codes · migration
-- ร้านสร้างประเภทคูปอง แล้วออกรหัสเป็นชุด
--
-- สองเรื่องที่เป็นแกนของ feature นี้
--   1 · plaintext ของรหัสไม่เคยอยู่ในฐานข้อมูล · เก็บแค่ hash สองตัว
--       code_hash  ใช้ค้นหาตอนลูกค้ายื่นรหัสมา
--       code_ref   ส่งขึ้น chain · เป็น hash ของ id ไม่ใช่ของ plaintext
--   2 · ออกเกินจำนวนที่ประกาศไว้ไม่ได้ · บังคับด้วย trigger ที่ตรวจผลรวม
--
-- อ้างอิง  RFD 2 §3.3 · RFD 3 D1 · RFD 11 §3.3 · RFD 14 L3
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

-- สถานะของประเภทคูปองในมุมของร้าน
CREATE TYPE coupon_type_status AS ENUM (
  'REQUESTED',   -- ประกาศแล้ว ยังไม่มี contract
  'LIVE',        -- deploy เสร็จ ออกรหัสได้
  'FAILED',      -- deploy ล้ม · ชื่อถูกปล่อยคืน
  'RETIRED'      -- เลิกออกเพิ่ม · ใบที่ออกไปแล้วยังใช้ได้
);

-- RFD 11 §3.2 · สถานะของรหัสแต่ละใบ
CREATE TYPE coupon_code_state AS ENUM (
  'ISSUED',      -- ออกแล้ว ยังไม่มีผู้ถือ
  'HELD',        -- มีผู้ถือ
  'REDEEMED',    -- ใช้ไปแล้ว
  'EXPIRED',     -- หมดอายุ
  'VOIDED'       -- ร้านยกเลิกก่อนแจก
);

CREATE TYPE holder_kind AS ENUM ('MERCHANT', 'CUSTOMER');
CREATE TYPE actor_type AS ENUM ('SYSTEM', 'MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

-- ---------------------------------------------------- ตัวตน (FEAT-01)
CREATE TABLE merchant (
  id         text PRIMARY KEY,
  name       text            NOT NULL,
  status     merchant_status NOT NULL DEFAULT 'PENDING',
  created_at timestamptz     NOT NULL DEFAULT now()
);

CREATE TABLE signer (
  address    bytea PRIMARY KEY CHECK (octet_length(address) = 20),
  key_ref    text    NOT NULL,
  next_nonce bigint  NOT NULL DEFAULT 0 CHECK (next_nonce >= 0),
  enabled    boolean NOT NULL DEFAULT true
);

-- ================================================= ประเภทคูปอง · ฝั่งร้าน
-- ไม่ใช่ projection · ชื่อและเงื่อนไขมาจากร้าน ไม่ได้มาจาก chain
CREATE TABLE coupon_type (
  id            text PRIMARY KEY,
  merchant_id   text               NOT NULL REFERENCES merchant(id),
  name          text               NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  -- RFD 14 · มูลค่าหน้าคูปองเป็น base units ของ THB
  face_value    numeric(78,0)      NOT NULL CHECK (face_value >= 0),
  -- จำนวนสูงสุดที่ออกได้ · ประกาศตอนสร้าง เปลี่ยนไม่ได้
  total_supply  integer            NOT NULL CHECK (total_supply BETWEEN 1 AND 1000000),
  status        coupon_type_status NOT NULL DEFAULT 'REQUESTED',
  expires_at    timestamptz        NOT NULL,
  created_at    timestamptz        NOT NULL DEFAULT now(),
  live_at       timestamptz,
  CONSTRAINT ck_coupon_type_expiry CHECK (expires_at > created_at),
  CONSTRAINT ck_coupon_type_live
    CHECK ((status = 'LIVE') = (live_at IS NOT NULL) OR status = 'RETIRED')
);

-- ชื่อซ้ำในร้านเดียวไม่ได้ · ยกเว้นอันที่ deploy ล้มไปแล้ว
CREATE UNIQUE INDEX uq_coupon_type_name
  ON coupon_type (merchant_id, lower(btrim(name))) WHERE status <> 'FAILED';
CREATE INDEX ix_coupon_type_merchant ON coupon_type (merchant_id, status);

-- ร้านที่ยังไม่ ACTIVE สร้างประเภทคูปองไม่ได้ (FEAT-01)
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

CREATE TRIGGER trg_coupon_type_merchant_active
  BEFORE INSERT ON coupon_type
  FOR EACH ROW EXECUTE FUNCTION f_merchant_must_be_active();

-- ================================================ ประเภทคูปอง · ฝั่ง chain
-- projection แท้ · ทุกค่า derive จาก chain_event ได้ (RFD 6 §3.2)
CREATE TABLE coupon_type_chain (
  coupon_type_id   text PRIMARY KEY REFERENCES coupon_type(id),
  contract_address bytea       NOT NULL CHECK (octet_length(contract_address) = 20),
  chain_type_id    numeric(78,0) NOT NULL,
  deployed_block   bigint      NOT NULL CHECK (deployed_block > 0),
  deployed_tx_hash bytea       NOT NULL CHECK (octet_length(deployed_tx_hash) = 32),
  applied_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_coupon_chain ON coupon_type_chain (contract_address, chain_type_id);

CREATE OR REPLACE FUNCTION f_coupon_chain_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contract_address <> OLD.contract_address
     OR NEW.chain_type_id <> OLD.chain_type_id THEN
    RAISE EXCEPTION 'coupon_type_chain เปลี่ยนค่าที่มาจาก chain ไม่ได้'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_coupon_chain_immutable
  BEFORE UPDATE ON coupon_type_chain
  FOR EACH ROW EXECUTE FUNCTION f_coupon_chain_immutable();

-- ========================================================= รหัสคูปอง
-- RFD 11 §3.3 · plaintext ไม่เคยอยู่ในตารางนี้
--
--   code_hash = sha256(plaintext)   ใช้ค้นหาตอนลูกค้ายื่นรหัสมา
--   code_ref  = sha256(id)          ส่งขึ้น chain
--
-- ทำไม code_ref ไม่ใช่ hash ของ plaintext
--   indexer และ projector ไม่เคยเห็น plaintext เลย
--   ถ้า code_ref มาจาก plaintext พวกมันจะจับคู่ event กลับมาหาแถวนี้ไม่ได้
--   ใช้ hash ของ id แทน ทำให้ทุกฝ่ายคำนวณค่าเดียวกันได้โดยไม่ต้องรู้รหัส
CREATE TABLE coupon_code (
  id             text PRIMARY KEY,
  coupon_type_id text              NOT NULL REFERENCES coupon_type(id),
  code_hash      bytea             NOT NULL CHECK (octet_length(code_hash) = 32),
  code_ref       bytea             NOT NULL CHECK (octet_length(code_ref) = 32),
  state          coupon_code_state NOT NULL DEFAULT 'ISSUED',
  holder_kind    holder_kind,
  holder_id      text,
  issue_batch_id text,
  issued_at      timestamptz       NOT NULL DEFAULT now(),
  held_at        timestamptz,
  redeemed_at    timestamptz,
  CONSTRAINT ck_code_holder
    CHECK ((holder_kind IS NULL) = (holder_id IS NULL)),
  CONSTRAINT ck_code_held
    CHECK (state <> 'HELD' OR holder_id IS NOT NULL),
  CONSTRAINT ck_code_redeemed
    CHECK ((state = 'REDEEMED') = (redeemed_at IS NOT NULL))
);
CREATE UNIQUE INDEX uq_code_hash ON coupon_code (code_hash);
CREATE UNIQUE INDEX uq_code_ref  ON coupon_code (code_ref);
CREATE INDEX ix_code_type_state ON coupon_code (coupon_type_id, state);
CREATE INDEX ix_code_holder ON coupon_code (holder_kind, holder_id) WHERE state = 'HELD';

-- code_ref ต้องเป็น sha256 ของ id เสมอ · ใครจะเขียนค่าอื่นไม่ได้
-- ข้อนี้ทำให้ projector คำนวณ code_ref เองได้โดยไม่ต้องอ่านตารางนี้
CREATE OR REPLACE FUNCTION f_code_ref_derived() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.code_ref <> sha256(convert_to(NEW.id, 'UTF8')) THEN
    RAISE EXCEPTION 'code_ref ต้องเท่ากับ sha256(id) เสมอ'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_code_ref_derived
  BEFORE INSERT OR UPDATE ON coupon_code
  FOR EACH ROW EXECUTE FUNCTION f_code_ref_derived();

-- ออกรหัสเกินจำนวนที่ประกาศไว้ไม่ได้
-- นับเฉพาะใบที่ยังไม่ถูกยกเลิก · VOIDED ปล่อยโควตาคืน
CREATE OR REPLACE FUNCTION f_issue_within_supply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_supply integer; v_issued integer;
BEGIN
  SELECT total_supply INTO v_supply FROM coupon_type WHERE id = NEW.coupon_type_id;
  -- serialize เฉพาะประเภทนี้จนจบ transaction
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.coupon_type_id, 1));
  SELECT count(*) INTO v_issued FROM coupon_code
   WHERE coupon_type_id = NEW.coupon_type_id AND state <> 'VOIDED';
  IF v_issued >= v_supply THEN
    RAISE EXCEPTION 'ออกรหัสเกินจำนวนที่ประกาศไว้ · supply % ออกไปแล้ว %', v_supply, v_issued
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_issue_within_supply
  BEFORE INSERT ON coupon_code
  FOR EACH ROW EXECUTE FUNCTION f_issue_within_supply();

-- ชุดการออกรหัส · หนึ่งคำขอหนึ่งชุด
CREATE TABLE issue_batch (
  id             text PRIMARY KEY,
  coupon_type_id text        NOT NULL REFERENCES coupon_type(id),
  operation_id   text,
  quantity       integer     NOT NULL CHECK (quantity BETWEEN 1 AND 10000),
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_batch_type ON issue_batch (coupon_type_id);

ALTER TABLE coupon_code
  ADD CONSTRAINT fk_code_batch FOREIGN KEY (issue_batch_id) REFERENCES issue_batch(id);

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
  id           text PRIMARY KEY,
  actor_scope  text             NOT NULL,
  kind         operation_kind   NOT NULL,
  status       operation_status NOT NULL DEFAULT 'PENDING',
  subject_id   text,
  payload      jsonb            NOT NULL,
  error_note   text,
  created_at   timestamptz      NOT NULL DEFAULT now(),
  finalized_at timestamptz,
  CONSTRAINT ck_finalized_consistent
    CHECK ((status = 'FINALIZED') = (finalized_at IS NOT NULL))
);
CREATE INDEX ix_operation_open ON operation (created_at)
  WHERE status NOT IN ('FINALIZED','CHAIN_REVERTED');

-- ประเภทคูปองหนึ่งอันมีงาน deploy ค้างได้ทีละงานเดียว
CREATE UNIQUE INDEX uq_coupon_deploy_inflight
  ON operation (subject_id)
  WHERE kind = 'COUPON_TYPE_CREATE'
    AND status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);
ALTER TABLE issue_batch
  ADD CONSTRAINT fk_batch_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

CREATE TABLE operation_step (
  id             text PRIMARY KEY,
  operation_id   text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  step_index     integer     NOT NULL CHECK (step_index >= 1),
  name           text        NOT NULL,
  -- จำนวนรหัสที่ mint ใน tx นี้
  mint_count     integer     NOT NULL DEFAULT 1 CHECK (mint_count BETWEEN 1 AND 500),
  signer_address bytea       REFERENCES signer(address),
  nonce          bigint      CHECK (nonce IS NULL OR nonce >= 0),
  raw_tx         bytea,
  tx_hash        bytea       CHECK (tx_hash IS NULL OR octet_length(tx_hash) = 32),
  status         step_status NOT NULL DEFAULT 'PENDING',
  submitted_at   timestamptz,
  confirmed_at   timestamptz,
  finalized_at   timestamptz,
  CONSTRAINT ck_rawtx_before_broadcast
    CHECK (status = 'PENDING' OR raw_tx IS NOT NULL)
);
CREATE UNIQUE INDEX uq_step_order   ON operation_step (operation_id, step_index);
CREATE UNIQUE INDEX uq_step_txhash  ON operation_step (tx_hash) WHERE tx_hash IS NOT NULL;
CREATE UNIQUE INDEX uq_signer_nonce ON operation_step (signer_address, nonce)
  WHERE signer_address IS NOT NULL AND nonce IS NOT NULL;

CREATE TABLE outbox (
  id           text PRIMARY KEY,
  operation_id text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  topic        text        NOT NULL CHECK (topic ~ '\.v[0-9]+$'),
  payload      jsonb       NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  sent_at      timestamptz
);
CREATE INDEX idx_outbox_pending ON outbox (created_at) WHERE sent_at IS NULL;

CREATE TABLE operation_event (
  id           text PRIMARY KEY,
  operation_id text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  from_status  operation_status,
  to_status    operation_status NOT NULL,
  actor        actor_type  NOT NULL DEFAULT 'SYSTEM',
  tx_hash      bytea,
  metadata     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
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

COMMIT;
