-- =====================================================================
-- FEAT-08 · List on Marketplace · migration
-- ร้านเอาคูปองที่ถืออยู่ไปลงขายใน marketplace
--
-- feature นี้คือเหตุผลหลักที่ operation_step ต้องมีอยู่ (RFD 2 D4)
-- การลงขายหนึ่งครั้งต้องยิงสาม tx ที่ต้องเรียงกัน
--   1 approveCoupon   ให้ marketplace ย้ายคูปองได้
--   2 createListing   สร้างรายการขายบน chain
--   3 lockInVault     ย้ายคูปองเข้า escrow
--
-- ของที่ลงขายคือ "ใบที่ระบุเจาะจง" ไม่ใช่ "จำนวน"
-- ขาย 5 จาก 10 ใบจึงเป็นเรื่องธรรมดา และระบุได้ว่าใบไหนบ้าง
--
-- อ้างอิง  RFD 2 §3.5 D4 · RFD 3 D1 · RFD 12 · RFD 14 L3
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
CREATE TYPE coupon_type_status AS ENUM ('REQUESTED', 'LIVE', 'FAILED', 'RETIRED');
CREATE TYPE coupon_code_state AS ENUM ('ISSUED', 'HELD', 'REDEEMED', 'EXPIRED', 'VOIDED');
CREATE TYPE holder_kind AS ENUM ('MERCHANT', 'CUSTOMER');
CREATE TYPE actor_type AS ENUM ('SYSTEM', 'MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

CREATE TYPE reservation_subject AS ENUM (
  'POINT_BALANCE', 'COUPON_UNIT', 'LISTING', 'THB_BALANCE', 'ESCROW'
);

-- สถานะของรายการขายในมุมของร้าน
CREATE TYPE listing_status AS ENUM (
  'PENDING',    -- ส่งคำขอแล้ว ยังไม่อยู่บน chain
  'ACTIVE',     -- ขายอยู่
  'SOLD',       -- ขายหมดแล้ว
  'DELISTED',   -- ถอดออกเอง
  'FAILED'      -- สร้างบน chain ไม่สำเร็จ
);

-- ------------------------------------------ ตัวตน (FEAT-01 · FEAT-07)
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

CREATE TABLE coupon_type (
  id           text PRIMARY KEY,
  merchant_id  text               NOT NULL REFERENCES merchant(id),
  name         text               NOT NULL,
  face_value   numeric(78,0)      NOT NULL CHECK (face_value >= 0),
  total_supply integer            NOT NULL CHECK (total_supply > 0),
  status       coupon_type_status NOT NULL DEFAULT 'REQUESTED',
  expires_at   timestamptz        NOT NULL
);

CREATE TABLE coupon_code (
  id             text PRIMARY KEY,
  coupon_type_id text              NOT NULL REFERENCES coupon_type(id),
  code_hash      bytea             NOT NULL CHECK (octet_length(code_hash) = 32),
  code_ref       bytea             NOT NULL CHECK (octet_length(code_ref) = 32),
  state          coupon_code_state NOT NULL DEFAULT 'ISSUED',
  holder_kind    holder_kind,
  holder_id      text,
  CONSTRAINT ck_code_holder CHECK ((holder_kind IS NULL) = (holder_id IS NULL))
);
CREATE UNIQUE INDEX uq_code_hash ON coupon_code (code_hash);
CREATE UNIQUE INDEX uq_code_ref  ON coupon_code (code_ref);
CREATE INDEX ix_code_holder ON coupon_code (holder_kind, holder_id) WHERE state = 'HELD';

-- ======================================================= รายการขาย
-- ฝั่งคำขอของร้าน · ราคาและจำนวนมาจากร้าน ไม่ได้มาจาก chain
CREATE TABLE listing (
  id             text PRIMARY KEY,
  seller_kind    holder_kind    NOT NULL,
  seller_id      text           NOT NULL,
  coupon_type_id text           NOT NULL REFERENCES coupon_type(id),
  -- RFD 14 · ราคาต่อใบ เป็น base units ของ THB
  unit_price     numeric(78,0)  NOT NULL CHECK (unit_price > 0),
  quantity       integer        NOT NULL CHECK (quantity BETWEEN 1 AND 500),
  status         listing_status NOT NULL DEFAULT 'PENDING',
  created_at     timestamptz    NOT NULL DEFAULT now(),
  active_at      timestamptz,
  closed_at      timestamptz,
  CONSTRAINT ck_listing_active CHECK ((status = 'ACTIVE') = (active_at IS NOT NULL)
                                       OR status IN ('SOLD','DELISTED')),
  CONSTRAINT ck_listing_closed CHECK ((status IN ('SOLD','DELISTED')) = (closed_at IS NOT NULL))
);
CREATE INDEX ix_listing_seller ON listing (seller_kind, seller_id, status);
CREATE INDEX ix_listing_browse ON listing (coupon_type_id, unit_price)
  WHERE status = 'ACTIVE';

-- ของที่ลงขายคือใบที่ระบุเจาะจง ไม่ใช่จำนวน
-- จึงบอกได้ว่าใบไหนบ้าง และขาย 5 จาก 10 ใบได้โดยธรรมชาติ
CREATE TABLE listing_item (
  id             text PRIMARY KEY,
  listing_id     text NOT NULL REFERENCES listing(id) ON DELETE CASCADE,
  coupon_code_id text NOT NULL REFERENCES coupon_code(id)
);
CREATE UNIQUE INDEX uq_item_in_listing ON listing_item (listing_id, coupon_code_id);
CREATE INDEX ix_item_code ON listing_item (coupon_code_id);

-- ฝั่งผลจาก chain · projection แท้ (RFD 6 §3.2)
CREATE TABLE listing_chain (
  listing_id       text PRIMARY KEY REFERENCES listing(id),
  contract_address bytea         NOT NULL CHECK (octet_length(contract_address) = 20),
  chain_listing_id numeric(78,0) NOT NULL,
  created_block    bigint        NOT NULL CHECK (created_block > 0),
  created_tx_hash  bytea         NOT NULL CHECK (octet_length(created_tx_hash) = 32),
  applied_at       timestamptz   NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_listing_chain ON listing_chain (contract_address, chain_listing_id);

CREATE OR REPLACE FUNCTION f_listing_chain_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contract_address <> OLD.contract_address
     OR NEW.chain_listing_id <> OLD.chain_listing_id THEN
    RAISE EXCEPTION 'listing_chain เปลี่ยนค่าที่มาจาก chain ไม่ได้'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_listing_chain_immutable
  BEFORE UPDATE ON listing_chain
  FOR EACH ROW EXECUTE FUNCTION f_listing_chain_immutable();

-- ลงขายได้เฉพาะใบที่ตัวเองถืออยู่จริง และยังไม่หมดอายุ
-- RFD 12 · เงื่อนไขนี้ต้องอยู่ในฐานข้อมูล ไม่ใช่แค่ guard ในโค้ด
-- เพราะระบบเดิมเช็คที่ api แล้วมีทางลัดที่ข้ามไปได้ (F5)
CREATE OR REPLACE FUNCTION f_listing_item_valid() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_state coupon_code_state; v_hk holder_kind; v_hid text;
  v_type text; v_exp timestamptz; v_lt text;
  v_sk holder_kind; v_sid text; v_ltype text;
BEGIN
  SELECT c.state, c.holder_kind, c.holder_id, c.coupon_type_id, t.expires_at
    INTO v_state, v_hk, v_hid, v_type, v_exp
    FROM coupon_code c JOIN coupon_type t ON t.id = c.coupon_type_id
   WHERE c.id = NEW.coupon_code_id;

  SELECT seller_kind, seller_id, coupon_type_id INTO v_sk, v_sid, v_ltype
    FROM listing WHERE id = NEW.listing_id;

  IF v_state <> 'HELD' THEN
    RAISE EXCEPTION 'คูปอง % อยู่สถานะ % ลงขายไม่ได้', NEW.coupon_code_id, v_state
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_hk IS DISTINCT FROM v_sk OR v_hid IS DISTINCT FROM v_sid THEN
    RAISE EXCEPTION 'คูปอง % ไม่ได้อยู่ในมือผู้ขาย', NEW.coupon_code_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_type IS DISTINCT FROM v_ltype THEN
    RAISE EXCEPTION 'คูปอง % คนละประเภทกับรายการขาย', NEW.coupon_code_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_exp <= now() THEN
    RAISE EXCEPTION 'คูปอง % หมดอายุไปแล้ว', NEW.coupon_code_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_listing_item_valid
  BEFORE INSERT ON listing_item
  FOR EACH ROW EXECUTE FUNCTION f_listing_item_valid();

-- จำนวนใบที่ใส่จริงต้องเท่ากับ quantity ที่ประกาศไว้
-- ตรวจตอนจบ transaction เพราะระหว่างใส่ทีละใบยังไม่ครบ
CREATE OR REPLACE FUNCTION f_listing_quantity_match() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_q integer; v_n integer;
BEGIN
  SELECT quantity INTO v_q FROM listing WHERE id = NEW.listing_id;
  SELECT count(*) INTO v_n FROM listing_item WHERE listing_id = NEW.listing_id;
  IF v_n > v_q THEN
    RAISE EXCEPTION 'ใส่คูปอง % ใบ เกิน quantity ที่ประกาศไว้ %', v_n, v_q
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_listing_quantity_match
  AFTER INSERT ON listing_item
  FOR EACH ROW EXECUTE FUNCTION f_listing_quantity_match();

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

-- รายการขายหนึ่งอันมีงานค้างได้ทีละงานเดียว
CREATE UNIQUE INDEX uq_listing_inflight
  ON operation (subject_id)
  WHERE kind IN ('LISTING_CREATE','LISTING_DELETE')
    AND status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

-- ลงขาย = สาม tx ที่ต้องเรียงกัน · นี่คือเหตุผลที่ตารางนี้ต้องมี (RFD 2 D4)
CREATE TABLE operation_step (
  id             text PRIMARY KEY,
  operation_id   text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  step_index     integer     NOT NULL CHECK (step_index >= 1),
  name           text        NOT NULL,
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

CREATE TABLE reservation (
  id           text PRIMARY KEY,
  operation_id text                NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  subject_type reservation_subject NOT NULL,
  subject_id   text                NOT NULL,
  amount       numeric(78,0)       NOT NULL CHECK (amount > 0),
  created_at   timestamptz         NOT NULL DEFAULT now(),
  released_at  timestamptz
);

-- RFD 12 D3 · ของชิ้นเดียวจองซ้อนไม่ได้
-- คูปองใบเดียวกันอยู่ในสองรายการขายพร้อมกันจึงเป็นไปไม่ได้
CREATE UNIQUE INDEX uq_reservation_exclusive
  ON reservation (subject_type, subject_id)
  WHERE released_at IS NULL
    AND subject_type IN ('COUPON_UNIT','LISTING','ESCROW');
CREATE INDEX ix_reservation_open
  ON reservation (subject_type, subject_id) WHERE released_at IS NULL;

-- RFD 9 · ปล่อยจองได้เมื่องานจบแล้วเท่านั้น
CREATE OR REPLACE FUNCTION f_check_release_timing() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE st operation_status;
BEGIN
  IF OLD.released_at IS NOT NULL OR NEW.released_at IS NULL THEN RETURN NEW; END IF;
  SELECT status INTO st FROM operation WHERE id = NEW.operation_id;
  IF st NOT IN ('FINALIZED','CHAIN_REVERTED') THEN
    RAISE EXCEPTION 'ปล่อยจองไม่ได้ · operation % ยังอยู่สถานะ %', NEW.operation_id, st
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_reservation_release_timing
  BEFORE UPDATE ON reservation
  FOR EACH ROW EXECUTE FUNCTION f_check_release_timing();

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
