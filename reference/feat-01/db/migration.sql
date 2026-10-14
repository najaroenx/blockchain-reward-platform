-- =====================================================================
-- FEAT-01 · Merchant Onboarding · migration
-- สมัครร้านค้า แล้ว provision wallet บน chain เป็นงานแยกที่ตามมาทีหลัง
-- อ้างอิง  RFD 2 §3.3 · RFD 3 D1 · RFD 4 L6 D3 · RFD 8 §3.4
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

-- RFD 8 §3.4 · ร้านมีตัวตนทันทีที่สมัคร (PENDING)
-- ACTIVE เขียนได้จาก projector เท่านั้น เมื่อ provision จบจริง
CREATE TYPE merchant_status AS ENUM ('PENDING', 'ACTIVE', 'SUSPENDED', 'CLOSED');

CREATE TYPE wallet_owner AS ENUM ('MERCHANT', 'CUSTOMER', 'PLATFORM');

CREATE TYPE actor_type AS ENUM ('SYSTEM', 'MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

-- ---------------------------------------------------------- ตัวร้านค้า
CREATE TABLE merchant (
  id          text PRIMARY KEY,
  name        text            NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  status      merchant_status NOT NULL DEFAULT 'PENDING',
  created_at  timestamptz     NOT NULL DEFAULT now(),
  activated_at timestamptz,
  CONSTRAINT ck_merchant_active
    CHECK ((status = 'ACTIVE') = (activated_at IS NOT NULL))
);
CREATE INDEX ix_merchant_pending ON merchant (created_at) WHERE status = 'PENDING';

-- RFD 8 §3.2 · ร้านคือหน่วยที่ถือสินทรัพย์ · คนคือหน่วยที่ล็อกอิน
-- ร้านหนึ่งมีแอดมินได้หลายคน จึงแยกตาราง
CREATE TABLE merchant_admin (
  id              text PRIMARY KEY,
  merchant_id     text        NOT NULL REFERENCES merchant(id),
  -- เก็บทั้งค่าที่ผู้ใช้พิมพ์ และค่าที่ normalize แล้ว
  -- unique อยู่บนค่าที่ normalize เท่านั้น (NFC + trim + lowercase)
  email            text       NOT NULL,
  email_normalized text       NOT NULL CHECK (email_normalized = lower(btrim(email_normalized))),
  -- RFD 8 D7 · argon2id · เก็บทั้ง PHC string ไม่แยกฟิลด์
  password_hash   text        NOT NULL CHECK (password_hash LIKE '$argon2id$%'),
  display_name    text        NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_login_at   timestamptz
);
CREATE UNIQUE INDEX uq_admin_email ON merchant_admin (email_normalized);
CREATE INDEX ix_admin_merchant ON merchant_admin (merchant_id);

-- RFD 4 L6 · ไม่มีคอลัมน์ private key ไม่มีวันมี
-- key_ref ชี้ไป KMS เท่านั้น · ดูการพิสูจน์ที่ tests/acceptance.sql T3
CREATE TABLE wallet (
  id          text PRIMARY KEY,
  address     bytea        NOT NULL CHECK (octet_length(address) = 20),
  key_ref     text         NOT NULL CHECK (length(key_ref) > 0),
  owner_kind  wallet_owner NOT NULL,
  owner_id    text         NOT NULL,
  created_at  timestamptz  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_wallet_address ON wallet (address);
CREATE UNIQUE INDEX uq_wallet_owner   ON wallet (owner_kind, owner_id);

-- RFD 4 §3.5 · signer ของระบบ จ่าย gas ยิง tx · คนละเรื่องกับ wallet ของร้าน
-- RFD 4 L5 · ห้ามใช้ address ของระบบเดิม ไม่งั้น nonce ชนกัน
CREATE TABLE signer (
  address     bytea PRIMARY KEY CHECK (octet_length(address) = 20),
  key_ref     text        NOT NULL,
  next_nonce  bigint      NOT NULL DEFAULT 0 CHECK (next_nonce >= 0),
  enabled     boolean     NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- -------------------------------------------- Group B · แกน write path
-- RFD 3 D1 · unique คือ (scope, key)
-- ตอนสมัครยังไม่มี actor → scope = anon:<sha256(normalized email)>
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
CREATE INDEX ix_idem_expiry ON idempotency_key (expires_at);

CREATE TABLE operation (
  id            text PRIMARY KEY,
  actor_scope   text             NOT NULL,
  kind          operation_kind   NOT NULL,
  status        operation_status NOT NULL DEFAULT 'PENDING',
  subject_id    text,                       -- merchant_id สำหรับงาน provision
  payload       jsonb            NOT NULL,
  error_note    text,
  created_at    timestamptz      NOT NULL DEFAULT now(),
  finalized_at  timestamptz,
  CONSTRAINT ck_finalized_consistent
    CHECK ((status = 'FINALIZED') = (finalized_at IS NOT NULL))
);
CREATE INDEX ix_operation_open ON operation (created_at)
  WHERE status NOT IN ('FINALIZED','CHAIN_REVERTED');

-- ร้านหนึ่งมีงาน provision ที่ยังไม่จบได้ทีละงานเดียว
CREATE UNIQUE INDEX uq_provision_inflight
  ON operation (subject_id)
  WHERE kind = 'MERCHANT_PROVISION'
    AND status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

-- RFD 2 D4 · หนึ่งแถวต่อหนึ่ง chain tx
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
  -- RFD 2 R2 · broadcast ได้ก็ต่อเมื่อ raw_tx ลงตารางแล้ว
  CONSTRAINT ck_rawtx_before_broadcast
    CHECK (status = 'PENDING' OR raw_tx IS NOT NULL)
);
CREATE UNIQUE INDEX uq_step_order  ON operation_step (operation_id, step_index);
CREATE UNIQUE INDEX uq_step_txhash ON operation_step (tx_hash) WHERE tx_hash IS NOT NULL;
-- nonce ของ signer ตัวหนึ่งห้ามถูกใช้ซ้ำ
CREATE UNIQUE INDEX uq_signer_nonce ON operation_step (signer_address, nonce)
  WHERE signer_address IS NOT NULL AND nonce IS NOT NULL;

-- RFD 2 D1 · commit พร้อม operation เสมอ
CREATE TABLE outbox (
  id            text PRIMARY KEY,
  operation_id  text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  topic         text        NOT NULL CHECK (topic ~ '\.v[0-9]+$'),  -- RFD 7 D9 · มีเวอร์ชันในชื่อ
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
CREATE INDEX ix_opevent_operation ON operation_event (operation_id, created_at);

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
-- RFD 5 D2 · re-index ช่วงเดิมซ้ำได้ปลอดภัย
CREATE UNIQUE INDEX uq_chain_event ON chain_event (tx_hash, log_index);

CREATE TABLE indexer_cursor (
  contract_address bytea PRIMARY KEY CHECK (octet_length(contract_address) = 20),
  last_block       bigint      NOT NULL,
  last_block_hash  bytea,
  updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMIT;
