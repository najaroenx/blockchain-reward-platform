-- =====================================================================
-- FEAT-11 · Redeem Coupon · migration
-- ตารางทั้งหมดที่ flow นี้แตะ · รันบน PostgreSQL 16 ได้ตรงๆ
-- อ้างอิง  RFD 2 §3.3 · RFD 3 §3.2 · RFD 11 §3.4 · RFD 13 §3.5
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

CREATE TYPE coupon_code_state AS ENUM (
  'ISSUED', 'HELD', 'REDEEMED', 'EXPIRED', 'VOIDED'
);

CREATE TYPE reservation_subject AS ENUM (
  'POINT_BALANCE', 'COUPON_UNIT', 'LISTING', 'THB_BALANCE', 'ESCROW'
);

CREATE TYPE actor_type AS ENUM ('SYSTEM', 'MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

-- ---------------------------------------------------- Group A · ตัวตน
CREATE TABLE merchant (
  id            text PRIMARY KEY,
  name          text        NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  status        text        NOT NULL DEFAULT 'PENDING',
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE customer (
  id            text PRIMARY KEY,
  tel_hash      bytea       NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_customer_tel ON customer (tel_hash);

-- RFD 4 L6 · ไม่มีคอลัมน์ private key ไม่มีวันมี
CREATE TABLE wallet (
  id            text PRIMARY KEY,
  address       bytea       NOT NULL CHECK (octet_length(address) = 20),
  key_ref       text        NOT NULL,
  owner_kind    text        NOT NULL CHECK (owner_kind IN ('MERCHANT','CUSTOMER','PLATFORM')),
  owner_id      text        NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_wallet_address ON wallet (address);
CREATE UNIQUE INDEX uq_wallet_owner   ON wallet (owner_kind, owner_id);

CREATE TABLE coupon_type (
  id                text PRIMARY KEY,
  merchant_id       text        NOT NULL REFERENCES merchant(id),
  name              text        NOT NULL,
  contract_address  bytea       NOT NULL CHECK (octet_length(contract_address) = 20),
  chain_type_id     numeric(78,0) NOT NULL,
  face_value        numeric(78,0) NOT NULL CHECK (face_value >= 0),  -- RFD 14 · base units
  expires_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_coupon_type_chain ON coupon_type (contract_address, chain_type_id);

-- RFD 11 §3.3 · เก็บ hash สำหรับ lookup · plaintext ไม่เคยอยู่ในตารางนี้
CREATE TABLE coupon_code (
  id            text PRIMARY KEY,
  coupon_type_id text       NOT NULL REFERENCES coupon_type(id),
  code_hash     bytea       NOT NULL CHECK (octet_length(code_hash) = 32),
  code_ref      bytea       NOT NULL CHECK (octet_length(code_ref) = 32),
  state         coupon_code_state NOT NULL DEFAULT 'ISSUED',
  holder_kind   text        CHECK (holder_kind IN ('MERCHANT','CUSTOMER')),
  holder_id     text,
  issued_at     timestamptz NOT NULL DEFAULT now(),
  redeemed_at   timestamptz,
  CONSTRAINT ck_redeemed_consistent
    CHECK ((state = 'REDEEMED') = (redeemed_at IS NOT NULL))
);
CREATE UNIQUE INDEX uq_coupon_code_hash ON coupon_code (code_hash);
CREATE UNIQUE INDEX uq_coupon_code_ref  ON coupon_code (code_ref);
CREATE INDEX ix_coupon_code_holder ON coupon_code (holder_kind, holder_id) WHERE state = 'HELD';

-- -------------------------------------------- Group B · แกน write path
-- RFD 3 D1 · scope ไม่ใช่ actor_id · FK ที่ null ได้ทำให้ unique ครอบไม่ครบ
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
  actor_scope   text        NOT NULL,
  kind          operation_kind   NOT NULL,
  status        operation_status NOT NULL DEFAULT 'PENDING',
  payload       jsonb       NOT NULL,
  error_note    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  finalized_at  timestamptz,
  CONSTRAINT ck_finalized_consistent
    CHECK ((status = 'FINALIZED') = (finalized_at IS NOT NULL))
);
CREATE INDEX ix_operation_open ON operation (created_at)
  WHERE status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

-- RFD 2 D4 · หนึ่งแถวต่อหนึ่ง chain tx
CREATE TABLE operation_step (
  id              text PRIMARY KEY,
  operation_id    text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  step_index      integer     NOT NULL CHECK (step_index >= 1),
  name            text        NOT NULL,
  signer_address  bytea       CHECK (signer_address IS NULL OR octet_length(signer_address) = 20),
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
CREATE UNIQUE INDEX uq_step_order ON operation_step (operation_id, step_index);
CREATE UNIQUE INDEX uq_step_txhash ON operation_step (tx_hash) WHERE tx_hash IS NOT NULL;
CREATE UNIQUE INDEX uq_signer_nonce ON operation_step (signer_address, nonce)
  WHERE signer_address IS NOT NULL AND nonce IS NOT NULL;

-- RFD 2 D1 · commit พร้อม operation เสมอ
CREATE TABLE outbox (
  id            text PRIMARY KEY,
  operation_id  text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  topic         text        NOT NULL,
  payload       jsonb       NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz
);
CREATE INDEX idx_outbox_pending ON outbox (created_at) WHERE sent_at IS NULL;

CREATE TABLE reservation (
  id            text PRIMARY KEY,
  operation_id  text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  subject_type  reservation_subject NOT NULL,
  subject_id    text        NOT NULL,
  amount        numeric(78,0) NOT NULL CHECK (amount > 0),
  created_at    timestamptz NOT NULL DEFAULT now(),
  released_at   timestamptz
);
-- RFD 11 D4 · หัวใจ · ของชิ้นเดียวจองซ้อนกันไม่ได้ในระดับฐานข้อมูล
CREATE UNIQUE INDEX uq_reservation_exclusive
  ON reservation (subject_type, subject_id)
  WHERE released_at IS NULL
    AND subject_type IN ('COUPON_UNIT','LISTING','ESCROW');

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
CREATE INDEX ix_chain_event_unapplied ON chain_event (block_number)
  WHERE applied_at IS NULL AND orphaned_at IS NULL;

-- ------------------------------------------ Group D · projection
CREATE TABLE coupon_holding (
  id              text PRIMARY KEY,
  coupon_type_id  text        NOT NULL REFERENCES coupon_type(id),
  holder_kind     text        NOT NULL CHECK (holder_kind IN ('MERCHANT','CUSTOMER')),
  holder_id       text        NOT NULL,
  quantity        numeric(78,0) NOT NULL CHECK (quantity >= 0),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_holding ON coupon_holding (coupon_type_id, holder_kind, holder_id);

-- RFD 13 §3.5 · escrow ผูกกับ tokenId หนึ่งก้อน · active ได้ทีละก้อน
CREATE TABLE escrow (
  id                text PRIMARY KEY,
  chain_token_id    numeric(78,0) NOT NULL,
  contract_address  bytea       NOT NULL CHECK (octet_length(contract_address) = 20),
  seller_wallet_id  text        NOT NULL REFERENCES wallet(id),
  buyer_wallet_id   text        NOT NULL REFERENCES wallet(id),
  total_amount      numeric(78,0) NOT NULL CHECK (total_amount >= 0),
  remaining_amount  numeric(78,0) NOT NULL CHECK (remaining_amount >= 0),
  coupons_locked    integer     NOT NULL CHECK (coupons_locked > 0),
  coupons_redeemed  integer     NOT NULL DEFAULT 0 CHECK (coupons_redeemed >= 0),
  active            boolean     NOT NULL DEFAULT true,
  locked_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_escrow_remaining CHECK (remaining_amount <= total_amount),
  CONSTRAINT ck_escrow_count     CHECK (coupons_redeemed <= coupons_locked)
);
CREATE UNIQUE INDEX uq_escrow_active
  ON escrow (contract_address, chain_token_id) WHERE active;

COMMIT;
