-- =====================================================================
-- FEAT-09 · Delist · migration
-- ร้านถอดรายการขายของตัวเองออกจาก marketplace
--
-- feature นี้มีอยู่เพื่อปิดช่องของระบบเดิมโดยตรง
--   F5 · delistMarketplaceListing.handler.ts เมื่อหา listing ไม่เจอ
--        โค้ดเซ็ต ownerId = merchantId เอง แล้วเดินต่อ
--        แปลว่า "หาไม่เจอ" กลายเป็น "ถือว่าเป็นของคนที่ขอ"
--   ที่นี่การหาไม่เจอคือการปฏิเสธ และการตรวจเจ้าของอยู่ในฐานข้อมูล
--   ไม่ใช่ guard ในโค้ดที่ข้ามได้
--
-- ถอดหนึ่งครั้ง = สอง tx ที่ต้องเรียงกัน
--   1 cancelListing     ปิดรายการบน chain ก่อน · ไม่มีใครซื้อได้อีก
--   2 releaseFromVault  คูปองออกจาก escrow กลับมาที่ผู้ขาย
-- สลับลำดับไม่ได้ · ถ้าเอาคูปองออกก่อนปิด จะมีช่วงที่รายการยังโฆษณา
-- ของที่ไม่อยู่ใน escrow แล้ว
--
-- อ้างอิง  F5 · RFD 2 §3.5 D4 · RFD 9 · RFD 12 D3 · RFD 14 L3
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

CREATE TYPE listing_status AS ENUM (
  'PENDING',    -- ส่งคำขอแล้ว ยังไม่อยู่บน chain
  'ACTIVE',     -- ขายอยู่ · ถอดได้เฉพาะสถานะนี้
  'SOLD',       -- ขายไปแล้ว · ถอดไม่ได้
  'DELISTED',   -- ถอดออกเองแล้ว
  'FAILED'      -- สร้างบน chain ไม่สำเร็จ
);

-- รายการบน chain ปิดเพราะอะไร · มาจาก event ไม่ได้มาจากความตั้งใจของ api
CREATE TYPE listing_close_reason AS ENUM ('CANCELLED', 'SOLD');

-- ------------------------------------------ ตัวตน (FEAT-01 · FEAT-07)
CREATE TABLE merchant (
  id         text PRIMARY KEY,
  name       text            NOT NULL,
  status     merchant_status NOT NULL DEFAULT 'PENDING',
  created_at timestamptz     NOT NULL DEFAULT now()
);

CREATE TABLE customer (
  id         text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
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
CREATE TABLE listing (
  id             text PRIMARY KEY,
  seller_kind    holder_kind    NOT NULL,
  seller_id      text           NOT NULL,
  coupon_type_id text           NOT NULL REFERENCES coupon_type(id),
  unit_price     numeric(78,0)  NOT NULL CHECK (unit_price > 0),
  quantity       integer        NOT NULL CHECK (quantity BETWEEN 1 AND 500),
  status         listing_status NOT NULL DEFAULT 'PENDING',
  created_at     timestamptz    NOT NULL DEFAULT now(),
  active_at      timestamptz,
  closed_at      timestamptz,
  -- FEAT-09 เข้มกว่า FEAT-08 · SOLD และ DELISTED แปลว่าเคย ACTIVE มาก่อน
  -- จึงต้องมี active_at ด้วย ไม่ใช่ปล่อยว่างได้
  CONSTRAINT ck_listing_active
    CHECK ((active_at IS NOT NULL) = (status IN ('ACTIVE','SOLD','DELISTED'))),
  CONSTRAINT ck_listing_closed
    CHECK ((closed_at IS NOT NULL) = (status IN ('SOLD','DELISTED'))),
  CONSTRAINT ck_listing_close_order
    CHECK (closed_at IS NULL OR closed_at >= active_at)
);
CREATE INDEX ix_listing_seller ON listing (seller_kind, seller_id, status);
CREATE INDEX ix_listing_browse ON listing (coupon_type_id, unit_price)
  WHERE status = 'ACTIVE';
CREATE INDEX ix_listing_closed ON listing (closed_at)
  WHERE status IN ('SOLD','DELISTED');

CREATE TABLE listing_item (
  id             text PRIMARY KEY,
  listing_id     text NOT NULL REFERENCES listing(id) ON DELETE CASCADE,
  coupon_code_id text NOT NULL REFERENCES coupon_code(id)
);
CREATE UNIQUE INDEX uq_item_in_listing ON listing_item (listing_id, coupon_code_id);
CREATE INDEX ix_item_code ON listing_item (coupon_code_id);

-- ฝั่งผลจาก chain · projection แท้ (RFD 6 §3.2)
-- การปิดรายการเขียนลงที่นี่เมื่อ indexer เห็น event ไม่ใช่เมื่อ api รับคำขอ
CREATE TABLE listing_chain (
  listing_id       text PRIMARY KEY REFERENCES listing(id),
  contract_address bytea         NOT NULL CHECK (octet_length(contract_address) = 20),
  chain_listing_id numeric(78,0) NOT NULL,
  created_block    bigint        NOT NULL CHECK (created_block > 0),
  created_tx_hash  bytea         NOT NULL CHECK (octet_length(created_tx_hash) = 32),
  closed_block     bigint        CHECK (closed_block IS NULL OR closed_block > 0),
  closed_tx_hash   bytea         CHECK (closed_tx_hash IS NULL
                                        OR octet_length(closed_tx_hash) = 32),
  close_reason     listing_close_reason,
  applied_at       timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_chain_close CHECK ((close_reason IS NULL) = (closed_block IS NULL)
                                   AND (close_reason IS NULL) = (closed_tx_hash IS NULL)),
  CONSTRAINT ck_chain_close_order
    CHECK (closed_block IS NULL OR closed_block >= created_block)
);
CREATE UNIQUE INDEX uq_listing_chain ON listing_chain (contract_address, chain_listing_id);

-- ค่าที่มาจาก chain แก้ไม่ได้ · และปิดแล้วปิดใหม่ด้วยเหตุผลอื่นไม่ได้
-- ถ้ามีคนซื้อตัดหน้า การยกเลิกจะ revert · ไม่ใช่เขียนทับว่า CANCELLED
CREATE OR REPLACE FUNCTION f_listing_chain_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contract_address <> OLD.contract_address
     OR NEW.chain_listing_id <> OLD.chain_listing_id
     OR NEW.created_block <> OLD.created_block
     OR NEW.created_tx_hash <> OLD.created_tx_hash THEN
    RAISE EXCEPTION 'listing_chain เปลี่ยนค่าที่มาจาก chain ไม่ได้'
      USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.close_reason IS NOT NULL
     AND NEW.close_reason IS DISTINCT FROM OLD.close_reason THEN
    RAISE EXCEPTION 'รายการ % ปิดด้วยเหตุผล % ไปแล้ว เปลี่ยนเป็น % ไม่ได้',
      OLD.listing_id, OLD.close_reason, NEW.close_reason
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_listing_chain_immutable
  BEFORE UPDATE ON listing_chain
  FOR EACH ROW EXECUTE FUNCTION f_listing_chain_immutable();

-- เงื่อนไขของคูปองตอนลงขาย (ยกมาจาก FEAT-08 · F5 เหมือนกัน)
CREATE OR REPLACE FUNCTION f_listing_item_valid() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_state coupon_code_state; v_hk holder_kind; v_hid text;
  v_type text; v_exp timestamptz;
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

-- ======================================================================
-- กฎข้อที่ 1 ของ FEAT-09 · เส้นทางของสถานะรายการขาย
--
-- DELISTED กับ SOLD เป็นปลายทาง · ออกจากทั้งสองไม่ได้
-- ถอดแล้วลงขายใหม่คือการสร้าง listing ใบใหม่ ไม่ใช่การปลุกใบเดิม
-- เพราะ chain_listing_id ของใบเดิมถูกยกเลิกไปแล้ว
-- ======================================================================
CREATE OR REPLACE FUNCTION f_listing_status_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;

  IF NOT (
       (OLD.status = 'PENDING' AND NEW.status IN ('ACTIVE','FAILED'))
    OR (OLD.status = 'ACTIVE'  AND NEW.status IN ('SOLD','DELISTED'))
  ) THEN
    RAISE EXCEPTION 'รายการขาย % เปลี่ยนสถานะจาก % ไป % ไม่ได้',
      OLD.id, OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- เติมเวลาให้เอง เพื่อให้ ck_listing_active / ck_listing_closed
  -- เป็นไปได้เสมอโดยที่ caller ไม่ต้องจำ
  IF NEW.status = 'ACTIVE' AND NEW.active_at IS NULL THEN
    NEW.active_at := now();
  END IF;
  IF NEW.status IN ('SOLD','DELISTED') AND NEW.closed_at IS NULL THEN
    NEW.closed_at := now();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_listing_status_transition
  BEFORE UPDATE ON listing
  FOR EACH ROW EXECUTE FUNCTION f_listing_status_transition();

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
  actor_scope  text             NOT NULL CHECK (actor_scope ~ '^(merchant|customer|admin|anon):.+$'),
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

-- ======================================================================
-- กฎข้อที่ 2 ของ FEAT-09 · รายการขายหนึ่งใบมีงานค้างได้ทีละงานเดียว
--
-- FEAT-08 ครอบแค่ LISTING_CREATE กับ LISTING_DELETE
-- FEAT-09 เพิ่ม LISTING_BUY เข้ามาด้วย เพราะนี่คือ feature แรก
-- ที่การแข่งกันเกิดขึ้นจริง · ร้านกดถอด ลูกค้ากดซื้อ พร้อมกัน
-- ใครแทรกแถว operation ได้ก่อนเป็นผู้ชนะ · ฐานข้อมูลตัดสิน ไม่ใช่โค้ด
--
-- ORPHANED และ MANUAL_REVIEW ไม่อยู่ในรายการยกเว้น จึงยังกันงานใหม่อยู่
-- รายการที่รอคนตรวจต้องไม่รับงานใหม่
-- ======================================================================
CREATE UNIQUE INDEX uq_listing_inflight
  ON operation (subject_id)
  WHERE kind IN ('LISTING_CREATE','LISTING_DELETE','LISTING_BUY')
    AND status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

-- ======================================================================
-- กฎข้อที่ 3 ของ FEAT-09 · การตรวจสิทธิ์ถอดรายการอยู่ในฐานข้อมูล
--
-- F5 คือต้นเรื่องของ trigger นี้
-- ระบบเดิม เมื่อหา listing ไม่เจอ เซ็ต ownerId = merchantId เองแล้วเดินต่อ
-- ที่นี่ "หาไม่เจอ" = ปฏิเสธ · "ไม่ใช่ของคุณ" = ปฏิเสธ
-- และปฏิเสธที่ชั้นเดียวกับที่เขียนข้อมูล จึงไม่มีทางลัดให้ข้าม
--
-- เจ้าของอ่านจาก actor_scope ของ operation เอง ไม่ใช่จาก payload
-- payload มาจาก request · actor_scope มาจาก token ที่ผ่าน auth แล้ว
-- ======================================================================
CREATE OR REPLACE FUNCTION f_delist_admissible() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_sk holder_kind; v_sid text; v_st listing_status;
  v_actor_kind text; v_actor_id text; v_expect holder_kind;
BEGIN
  IF NEW.kind <> 'LISTING_DELETE' THEN RETURN NEW; END IF;

  IF NEW.subject_id IS NULL THEN
    RAISE EXCEPTION 'operation LISTING_DELETE ต้องระบุ subject_id'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT seller_kind, seller_id, status INTO v_sk, v_sid, v_st
    FROM listing WHERE id = NEW.subject_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบรายการขาย %', NEW.subject_id
      USING ERRCODE = 'check_violation';
  END IF;

  v_actor_kind := split_part(NEW.actor_scope, ':', 1);
  v_actor_id   := split_part(NEW.actor_scope, ':', 2);

  IF v_actor_kind = 'admin' THEN
    -- platform admin ถอดได้ทุกใบ · บันทึกไว้ใน operation_event ว่าใครสั่ง
    NULL;
  ELSE
    v_expect := CASE v_actor_kind
                  WHEN 'merchant' THEN 'MERCHANT'::holder_kind
                  WHEN 'customer' THEN 'CUSTOMER'::holder_kind
                  ELSE NULL
                END;
    IF v_expect IS NULL OR v_expect <> v_sk OR v_actor_id <> v_sid THEN
      RAISE EXCEPTION 'รายการขาย % ไม่ใช่ของ %', NEW.subject_id, NEW.actor_scope
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF v_st <> 'ACTIVE' THEN
    RAISE EXCEPTION 'รายการขาย % อยู่สถานะ % ถอดไม่ได้', NEW.subject_id, v_st
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_delist_admissible
  BEFORE INSERT ON operation
  FOR EACH ROW EXECUTE FUNCTION f_delist_admissible();

-- ถอด = สอง tx เรียงกัน · cancelListing ก่อน releaseFromVault
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
  -- R2 · raw_tx ต้อง commit ก่อน broadcast
  CONSTRAINT ck_rawtx_before_broadcast
    CHECK (status = 'PENDING' OR raw_tx IS NOT NULL)
);
CREATE UNIQUE INDEX uq_step_order   ON operation_step (operation_id, step_index);
CREATE UNIQUE INDEX uq_step_name    ON operation_step (operation_id, name);
CREATE UNIQUE INDEX uq_step_txhash  ON operation_step (tx_hash) WHERE tx_hash IS NOT NULL;
CREATE UNIQUE INDEX uq_signer_nonce ON operation_step (signer_address, nonce)
  WHERE signer_address IS NOT NULL AND nonce IS NOT NULL;
CREATE INDEX ix_step_open ON operation_step (operation_id, step_index)
  WHERE status IN ('PENDING','SUBMITTED');

-- ======================================================================
-- กฎข้อที่ 4 ของ FEAT-09 · step ยิงเรียงกันจริง
--
-- ขั้นที่ n จะ SUBMITTED ได้เมื่อขั้นที่ n-1 FINALIZED แล้วเท่านั้น
-- releaseFromVault ก่อน cancelListing จะเปิดช่วงที่รายการยังโฆษณา
-- ของที่ไม่อยู่ใน escrow แล้ว · worker เขียนผิดลำดับได้ จึงกันที่ฐานข้อมูล
-- ======================================================================
CREATE OR REPLACE FUNCTION f_step_order_gate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_prev step_status;
BEGIN
  IF NEW.status = 'PENDING' OR NEW.step_index = 1 THEN RETURN NEW; END IF;
  IF OLD.status <> 'PENDING' THEN RETURN NEW; END IF;

  SELECT status INTO v_prev FROM operation_step
   WHERE operation_id = NEW.operation_id AND step_index = NEW.step_index - 1;

  IF v_prev IS DISTINCT FROM 'FINALIZED' THEN
    RAISE EXCEPTION 'ขั้นที่ % ยิงไม่ได้ · ขั้นที่ % อยู่สถานะ %',
      NEW.step_index, NEW.step_index - 1, coalesce(v_prev::text, 'ไม่มีแถว')
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_step_order_gate
  BEFORE UPDATE ON operation_step
  FOR EACH ROW EXECUTE FUNCTION f_step_order_gate();

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

CREATE UNIQUE INDEX uq_reservation_exclusive
  ON reservation (subject_type, subject_id)
  WHERE released_at IS NULL
    AND subject_type IN ('COUPON_UNIT','LISTING','ESCROW');
CREATE INDEX ix_reservation_open
  ON reservation (subject_type, subject_id) WHERE released_at IS NULL;
CREATE INDEX ix_reservation_by_op ON reservation (operation_id);

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

-- ======================================================================
-- กฎข้อที่ 5 ของ FEAT-09 · ปิดรายการก่อน แล้วค่อยปล่อยคูปอง
--
-- ลำดับนี้คือเรื่องเดียวกับลำดับของ step แต่บังคับที่ฝั่งข้อมูล
-- ถ้าปล่อยคูปองได้ตอนที่รายการยัง ACTIVE จะมีช่วงที่หน้า marketplace
-- ยังโฆษณาคูปองที่ถูกปล่อยไปลงขายใบอื่นแล้ว
--
-- จองคูปองของ FEAT-08 เป็นของ operation LISTING_CREATE
-- ซึ่ง FINALIZED ไปนานแล้ว · trg_reservation_release_timing จึงผ่าน
-- trigger นี้คือชั้นที่สองที่ดูสถานะของ "ของ" ไม่ใช่สถานะของ "งาน"
-- ======================================================================
CREATE OR REPLACE FUNCTION f_coupon_hold_until_closed() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_lst text; v_st listing_status;
BEGIN
  IF OLD.released_at IS NOT NULL OR NEW.released_at IS NULL THEN RETURN NEW; END IF;
  IF NEW.subject_type <> 'COUPON_UNIT' THEN RETURN NEW; END IF;

  SELECT l.id, l.status INTO v_lst, v_st
    FROM listing_item li JOIN listing l ON l.id = li.listing_id
   WHERE li.coupon_code_id = NEW.subject_id
     AND l.status IN ('PENDING','ACTIVE')
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'ปล่อยคูปอง % ไม่ได้ · รายการขาย % ยังอยู่สถานะ %',
      NEW.subject_id, v_lst, v_st
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_coupon_hold_until_closed
  BEFORE UPDATE ON reservation
  FOR EACH ROW EXECUTE FUNCTION f_coupon_hold_until_closed();

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
CREATE INDEX ix_opevent_by_op ON operation_event (operation_id, created_at);

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
CREATE INDEX ix_chain_event_unapplied ON chain_event (block_number)
  WHERE applied_at IS NULL AND orphaned_at IS NULL;

COMMIT;
