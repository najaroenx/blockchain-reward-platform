-- =====================================================================
-- FEAT-10 · Buy Coupon · migration
-- ลูกค้าซื้อคูปองจาก marketplace · เงินเปลี่ยนมือจริง
--
-- feature นี้ปิดสองช่องของระบบเดิมที่อยู่ตรงข้ามกันพอดี
--
--   F8 · Vault.json มี lockFunds releaseFundsPartial returnFunds ครบ
--        grep ทั้ง repo ไม่เจอผู้เรียกเลย → เงินไม่เคยถึงผู้ขาย
--        ที่นี่การเคลื่อนเงินถูกบันทึกเป็น ledger_entry ที่ต้องรวมได้ศูนย์
--        จึงไม่มีทางที่เงินจะ "หายไป" หรือ "ไม่ถึง" โดยที่ไม่มีใครเห็น
--
--   F4 · autoMintIfNeeded เสก THB ขึ้นมาด้วย admin key เมื่อยอดไม่พอ
--        ที่นี่ยอดไม่พอ = ปฏิเสธ · ไม่มีทางอื่น
--        และยอดคงเหลือทุกบัญชีต้องเท่ากับผลรวม ledger ของมันเสมอ
--        จะเพิ่มยอดโดยไม่มีคู่บัญชีไม่ได้เลยในระดับ schema
--
-- ซื้อหนึ่งครั้ง = สอง tx
--   1 approveTHB       ให้ marketplace ใช้ THB ได้เท่ายอดที่ต้องจ่ายพอดี
--   2 executePurchase  tx เดียวที่ย้ายทั้งเงินและคูปอง · atomic
--
-- ขั้นที่ 2 เป็น tx เดียวโดยตั้งใจ · ถ้าแยกเงินกับของเป็นสอง tx
-- จะมีสถานะ "จ่ายแล้วแต่ไม่ได้ของ" ที่ต้องเขียนทางกู้คืน
-- และทางกู้คืนนั้นคือที่ที่ F8 ตายไป — มีฟังก์ชันแต่ไม่มีใครเรียก
--
-- อ้างอิง  F4 · F8 · RFD 2 §3.5 · RFD 9 · RFD 12 · RFD 14 L3
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

CREATE TYPE listing_status AS ENUM ('PENDING','ACTIVE','SOLD','DELISTED','FAILED');
CREATE TYPE listing_close_reason AS ENUM ('CANCELLED', 'SOLD');

CREATE TYPE purchase_status AS ENUM (
  'PENDING',   -- รับคำขอแล้ว · เงินถูกกันไว้ ยังไม่ย้าย
  'SETTLED',   -- executePurchase FINALIZED · เงินและของย้ายแล้ว
  'FAILED'     -- tx revert · เงินที่กันไว้ถูกปล่อยคืน
);

-- ======================================================================
-- บัญชีในสมุด
--
-- ISSUANCE เป็นบัญชีคู่ของการนำ THB เข้าระบบ · ยอดติดลบเป็นเรื่องปกติ
-- และค่าติดลบของมันต้องเท่ากับผลรวมของทุกบัญชีที่เหลือเสมอ
-- นั่นคือ "THB ที่หมุนอยู่ในระบบทั้งหมด"
--
-- F4 พังข้อนี้ · autoMint เพิ่มยอดฝั่งเดียวโดยไม่มีคู่บัญชี
-- ที่นี่ทำแบบนั้นไม่ได้เลย เพราะ trg_ledger_balanced จะไม่ยอม commit
-- ======================================================================
CREATE TYPE ledger_account AS ENUM (
  'CUSTOMER_THB', 'MERCHANT_THB', 'PLATFORM_THB', 'ISSUANCE'
);

-- ------------------------------------------ ตัวตน (FEAT-01 · FEAT-02)
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
  CONSTRAINT ck_listing_active
    CHECK ((active_at IS NOT NULL) = (status IN ('ACTIVE','SOLD','DELISTED'))),
  CONSTRAINT ck_listing_closed
    CHECK ((closed_at IS NOT NULL) = (status IN ('SOLD','DELISTED')))
);
CREATE INDEX ix_listing_seller ON listing (seller_kind, seller_id, status);
CREATE INDEX ix_listing_browse ON listing (coupon_type_id, unit_price)
  WHERE status = 'ACTIVE';

CREATE TABLE listing_item (
  id             text PRIMARY KEY,
  listing_id     text NOT NULL REFERENCES listing(id) ON DELETE CASCADE,
  coupon_code_id text NOT NULL REFERENCES coupon_code(id)
);
CREATE UNIQUE INDEX uq_item_in_listing ON listing_item (listing_id, coupon_code_id);
CREATE INDEX ix_item_code ON listing_item (coupon_code_id);

CREATE TABLE listing_chain (
  listing_id       text PRIMARY KEY REFERENCES listing(id),
  contract_address bytea         NOT NULL CHECK (octet_length(contract_address) = 20),
  chain_listing_id numeric(78,0) NOT NULL,
  created_block    bigint        NOT NULL CHECK (created_block > 0),
  created_tx_hash  bytea         NOT NULL CHECK (octet_length(created_tx_hash) = 32),
  closed_block     bigint,
  closed_tx_hash   bytea,
  close_reason     listing_close_reason,
  applied_at       timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_chain_close CHECK ((close_reason IS NULL) = (closed_block IS NULL))
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
  IF OLD.close_reason IS NOT NULL
     AND NEW.close_reason IS DISTINCT FROM OLD.close_reason THEN
    RAISE EXCEPTION 'รายการ % ปิดด้วยเหตุผล % ไปแล้ว', OLD.listing_id, OLD.close_reason
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_listing_chain_immutable
  BEFORE UPDATE ON listing_chain
  FOR EACH ROW EXECUTE FUNCTION f_listing_chain_immutable();

-- ======================================================================
-- ราคาและจำนวนแก้ไม่ได้หลังขึ้นขาย
--
-- คนซื้อเห็นราคาหนึ่งแล้วกดซื้อ · ถ้าผู้ขายแก้ราคาได้ระหว่างนั้น
-- จะเกิดคำถามว่าควรคิดราคาไหน และคำตอบที่ถูกคือ "แก้ไม่ได้ตั้งแต่ต้น"
-- ง่ายกว่าและไม่มีกรณีขอบ
-- ======================================================================
CREATE OR REPLACE FUNCTION f_listing_price_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status <> 'PENDING'
     AND (NEW.unit_price <> OLD.unit_price OR NEW.quantity <> OLD.quantity) THEN
    RAISE EXCEPTION 'รายการ % ขึ้นขายแล้ว แก้ราคาหรือจำนวนไม่ได้', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_listing_price_immutable
  BEFORE UPDATE ON listing
  FOR EACH ROW EXECUTE FUNCTION f_listing_price_immutable();

CREATE OR REPLACE FUNCTION f_listing_status_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;
  IF NOT (
       (OLD.status = 'PENDING' AND NEW.status IN ('ACTIVE','FAILED'))
    OR (OLD.status = 'ACTIVE'  AND NEW.status IN ('SOLD','DELISTED'))
  ) THEN
    RAISE EXCEPTION 'รายการขาย % เปลี่ยนสถานะจาก % ไป % ไม่ได้',
      OLD.id, OLD.status, NEW.status USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status = 'ACTIVE'  AND NEW.active_at IS NULL THEN NEW.active_at := now(); END IF;
  IF NEW.status IN ('SOLD','DELISTED') AND NEW.closed_at IS NULL THEN
    NEW.closed_at := now();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_listing_status_transition
  BEFORE UPDATE ON listing
  FOR EACH ROW EXECUTE FUNCTION f_listing_status_transition();

-- ======================================================================
-- ค่าธรรมเนียม · อัตราที่ใช้คืออัตราที่มีผลตอนซื้อ
--
-- เก็บเป็นตารางที่มี effective_from ไม่ใช่ค่าคงที่ในโค้ด
-- เปลี่ยนอัตราวันนี้ต้องไม่ทำให้ยอดของการซื้อเมื่อวานเปลี่ยนตาม
-- purchase.fee_bps จึงบันทึกอัตราที่ใช้จริงไว้ในแถวนั้นเลย
-- ======================================================================
CREATE TABLE fee_schedule (
  id             text PRIMARY KEY,
  bps            integer     NOT NULL CHECK (bps BETWEEN 0 AND 10000),
  effective_from timestamptz NOT NULL,
  note           text
);
CREATE UNIQUE INDEX uq_fee_effective ON fee_schedule (effective_from);

CREATE OR REPLACE FUNCTION f_fee_bps_at(p_at timestamptz) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT bps FROM fee_schedule
   WHERE effective_from <= p_at
   ORDER BY effective_from DESC LIMIT 1
$$;

-- ======================================================================
-- ยอด THB · projection ที่ต้องเท่ากับผลรวม ledger ของบัญชีนั้นเสมอ
--
-- ไม่มี setter · ไม่มีทางเพิ่มยอดโดยไม่เขียน ledger คู่กัน
-- นี่คือคำตอบเชิงโครงสร้างต่อ F4
-- ======================================================================
CREATE TABLE thb_balance (
  account    ledger_account NOT NULL,
  account_id text           NOT NULL,
  amount     numeric(78,0)  NOT NULL DEFAULT 0,
  updated_at timestamptz    NOT NULL DEFAULT now(),
  PRIMARY KEY (account, account_id),
  -- ISSUANCE ติดลบได้และต้องติดลบ · บัญชีอื่นติดลบไม่ได้
  CONSTRAINT ck_balance_sign CHECK (amount >= 0 OR account = 'ISSUANCE')
);

-- ======================================================================
-- สมุดบัญชีคู่ · ทุกการเคลื่อนเงินต้องรวมได้ศูนย์ต่อหนึ่ง operation
--
-- F8 คือการที่เงินไม่เคยถึงผู้ขาย โดยที่ไม่มีอะไรในระบบส่งเสียง
-- ตารางนี้ทำให้ความเงียบแบบนั้นเป็นไปไม่ได้
--   เงินออกจากคนซื้อ แต่ไม่เข้าใครเลย      → ผลรวมไม่ศูนย์ → ไม่ commit
--   เงินเข้าผู้ขาย แต่ไม่ได้ออกจากใคร        → ผลรวมไม่ศูนย์ → ไม่ commit
-- ======================================================================
CREATE TABLE ledger_entry (
  id           text           PRIMARY KEY,
  operation_id text           NOT NULL,
  entry_seq    integer        NOT NULL CHECK (entry_seq >= 1),
  account      ledger_account NOT NULL,
  account_id   text           NOT NULL,
  asset        text           NOT NULL DEFAULT 'THB' CHECK (asset = 'THB'),
  -- เครื่องหมายมีความหมาย · ลบคือออก บวกคือเข้า · ศูนย์ไม่มีความหมาย
  amount       numeric(78,0)  NOT NULL CHECK (amount <> 0),
  memo         text,
  created_at   timestamptz    NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_ledger_seq ON ledger_entry (operation_id, entry_seq);
CREATE INDEX ix_ledger_account ON ledger_entry (account, account_id, created_at);

-- ======================================================= บันทึกการซื้อ
CREATE TABLE purchase (
  id           text            PRIMARY KEY,
  listing_id   text            NOT NULL REFERENCES listing(id),
  buyer_kind   holder_kind     NOT NULL,
  buyer_id     text            NOT NULL,
  seller_kind  holder_kind     NOT NULL,
  seller_id    text            NOT NULL,
  -- คัดลอกมาตอนรับคำขอ · ไม่อ่านจาก listing ย้อนหลัง
  unit_price   numeric(78,0)   NOT NULL CHECK (unit_price > 0),
  quantity     integer         NOT NULL CHECK (quantity > 0),
  total_price  numeric(78,0)   NOT NULL CHECK (total_price > 0),
  fee_bps      integer         NOT NULL CHECK (fee_bps BETWEEN 0 AND 10000),
  fee_amount   numeric(78,0)   NOT NULL CHECK (fee_amount >= 0),
  net_to_seller numeric(78,0)  NOT NULL CHECK (net_to_seller >= 0),
  status       purchase_status NOT NULL DEFAULT 'PENDING',
  operation_id text            NOT NULL,
  created_at   timestamptz     NOT NULL DEFAULT now(),
  settled_at   timestamptz,
  CONSTRAINT ck_purchase_settled CHECK ((status = 'SETTLED') = (settled_at IS NOT NULL)),
  CONSTRAINT ck_no_self_trade CHECK (NOT (buyer_kind = seller_kind AND buyer_id = seller_id))
);
CREATE UNIQUE INDEX uq_purchase_listing ON purchase (listing_id)
  WHERE status <> 'FAILED';
CREATE INDEX ix_purchase_buyer ON purchase (buyer_kind, buyer_id, created_at);

-- ======================================================================
-- เลขของการซื้อต้องตรงกันเองทุกช่อง
--
-- ตรวจที่ฐานข้อมูลเพราะเลขพวกนี้คำนวณในโค้ด และโค้ดปัดเศษผิดได้
-- fee + net ต้องเท่ากับ total พอดี ไม่ขาดไม่เกินแม้หนึ่งหน่วยเล็กสุด
-- ======================================================================
CREATE OR REPLACE FUNCTION f_purchase_math() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_expect_fee numeric(78,0);
BEGIN
  IF NEW.total_price <> NEW.unit_price * NEW.quantity THEN
    RAISE EXCEPTION 'total_price % ไม่เท่ากับ unit_price % คูณ %',
      NEW.total_price, NEW.unit_price, NEW.quantity
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.fee_amount + NEW.net_to_seller <> NEW.total_price THEN
    RAISE EXCEPTION 'fee % บวก net % ไม่เท่ากับ total %',
      NEW.fee_amount, NEW.net_to_seller, NEW.total_price
      USING ERRCODE = 'check_violation';
  END IF;
  -- ปัดลงเสมอ · ส่วนที่ปัดหายไปตกเป็นของผู้ขาย ไม่ใช่ของ platform
  v_expect_fee := div(NEW.total_price * NEW.fee_bps, 10000);
  IF NEW.fee_amount <> v_expect_fee THEN
    RAISE EXCEPTION 'fee % ไม่ตรงกับที่คำนวณจาก bps % (ควรเป็น %)',
      NEW.fee_amount, NEW.fee_bps, v_expect_fee
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_purchase_math
  BEFORE INSERT OR UPDATE ON purchase
  FOR EACH ROW EXECUTE FUNCTION f_purchase_math();

-- ----------------------------------- projection ของใครถือคูปองใบไหน
CREATE TABLE coupon_holding (
  coupon_code_id text PRIMARY KEY REFERENCES coupon_code(id),
  holder_kind    holder_kind NOT NULL,
  holder_id      text        NOT NULL,
  -- ย้ายมือได้เฉพาะเมื่อมี event รองรับ · ไม่มี event ไม่มีการย้าย
  chain_event_id text        NOT NULL,
  applied_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_holding_holder ON coupon_holding (holder_kind, holder_id);

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
  actor_scope  text             NOT NULL
                 CHECK (actor_scope ~ '^(merchant|customer|admin|anon):.+$'),
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

-- รายการขายหนึ่งใบมีงานค้างได้ทีละงานเดียว · ซื้อกับถอดแข่งกันที่นี่
CREATE UNIQUE INDEX uq_listing_inflight
  ON operation (subject_id)
  WHERE kind IN ('LISTING_CREATE','LISTING_DELETE','LISTING_BUY')
    AND status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);
ALTER TABLE ledger_entry
  ADD CONSTRAINT fk_ledger_operation FOREIGN KEY (operation_id) REFERENCES operation(id);
ALTER TABLE purchase
  ADD CONSTRAINT fk_purchase_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

-- ======================================================================
-- ซื้อได้ไหม · ตรวจที่ฐานข้อมูลเหมือน FEAT-09
--   ก  รายการมีอยู่จริง
--   ข  สถานะ ACTIVE
--   ค  คนซื้อไม่ใช่คนขาย
-- ======================================================================
CREATE OR REPLACE FUNCTION f_buy_admissible() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_sk holder_kind; v_sid text; v_st listing_status;
  v_actor_kind text; v_actor_id text; v_buyer holder_kind;
BEGIN
  IF NEW.kind <> 'LISTING_BUY' THEN RETURN NEW; END IF;

  IF NEW.subject_id IS NULL THEN
    RAISE EXCEPTION 'operation LISTING_BUY ต้องระบุ subject_id'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT seller_kind, seller_id, status INTO v_sk, v_sid, v_st
    FROM listing WHERE id = NEW.subject_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบรายการขาย %', NEW.subject_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_st <> 'ACTIVE' THEN
    RAISE EXCEPTION 'รายการขาย % อยู่สถานะ % ซื้อไม่ได้', NEW.subject_id, v_st
      USING ERRCODE = 'check_violation';
  END IF;

  v_actor_kind := split_part(NEW.actor_scope, ':', 1);
  v_actor_id   := split_part(NEW.actor_scope, ':', 2);
  v_buyer := CASE v_actor_kind
               WHEN 'merchant' THEN 'MERCHANT'::holder_kind
               WHEN 'customer' THEN 'CUSTOMER'::holder_kind
               ELSE NULL END;
  IF v_buyer IS NULL THEN
    RAISE EXCEPTION 'scope % ซื้อไม่ได้ · ต้องเป็น merchant หรือ customer',
      NEW.actor_scope USING ERRCODE = 'check_violation';
  END IF;
  IF v_buyer = v_sk AND v_actor_id = v_sid THEN
    RAISE EXCEPTION 'ซื้อรายการขายของตัวเองไม่ได้'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_buy_admissible
  BEFORE INSERT ON operation
  FOR EACH ROW EXECUTE FUNCTION f_buy_admissible();

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
CREATE UNIQUE INDEX uq_step_name    ON operation_step (operation_id, name);
CREATE UNIQUE INDEX uq_step_txhash  ON operation_step (tx_hash) WHERE tx_hash IS NOT NULL;
CREATE UNIQUE INDEX uq_signer_nonce ON operation_step (signer_address, nonce)
  WHERE signer_address IS NOT NULL AND nonce IS NOT NULL;

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
      NEW.step_index, NEW.step_index - 1, coalesce(v_prev::text,'ไม่มีแถว')
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

-- ของชิ้นเดียวจองซ้อนไม่ได้ · THB ไม่อยู่ในรายการนี้เพราะเป็นของบวกกันได้
CREATE UNIQUE INDEX uq_reservation_exclusive
  ON reservation (subject_type, subject_id)
  WHERE released_at IS NULL
    AND subject_type IN ('COUPON_UNIT','LISTING','ESCROW');
CREATE INDEX ix_reservation_open
  ON reservation (subject_type, subject_id) WHERE released_at IS NULL;
CREATE INDEX ix_reservation_by_op ON reservation (operation_id);

CREATE OR REPLACE FUNCTION f_reserved_thb(p_account_id text) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(amount), 0) FROM reservation
   WHERE subject_type = 'THB_BALANCE' AND subject_id = p_account_id
     AND released_at IS NULL
$$;

CREATE OR REPLACE FUNCTION f_available_thb(
  p_account ledger_account, p_account_id text
) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT greatest(
    coalesce((SELECT amount FROM thb_balance
               WHERE account = p_account AND account_id = p_account_id), 0)
    - f_reserved_thb(p_account_id), 0)
$$;

-- ======================================================================
-- ยอดไม่พอ = ปฏิเสธ · นี่คือจุดที่ F4 เคยเสกเงินขึ้นมา
--
-- THB เป็นของบวกกันได้ · partial unique index ใช้ไม่ได้
-- จึงล็อกด้วย advisory lock ต่อบัญชี แล้วคำนวณยอดที่ใช้ได้
-- สองคำขอพร้อมกันจึงเข้าคิวกัน ไม่ใช่ทั้งคู่อ่านยอดเดิมแล้วผ่านทั้งคู่ (F1)
-- ======================================================================
CREATE OR REPLACE FUNCTION f_thb_reservation_balance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_acct ledger_account; v_avail numeric;
BEGIN
  IF NEW.subject_type <> 'THB_BALANCE' THEN RETURN NEW; END IF;

  -- subject_id เขียนเป็น '<ACCOUNT>:<id>' · ตรวจส่วนประกอบก่อน cast
  -- cast ก่อนตรวจจะได้ 22P02 ซึ่งบอกอะไรไม่ได้
  IF position(':' in NEW.subject_id) = 0 THEN
    RAISE EXCEPTION 'subject_id ของ THB_BALANCE ต้องเป็น <ACCOUNT>:<id> · ได้ %',
      NEW.subject_id USING ERRCODE = 'check_violation';
  END IF;
  IF split_part(NEW.subject_id, ':', 1)
       NOT IN ('CUSTOMER_THB','MERCHANT_THB','PLATFORM_THB') THEN
    RAISE EXCEPTION 'บัญชี % ใช้จอง THB ไม่ได้', split_part(NEW.subject_id, ':', 1)
      USING ERRCODE = 'check_violation';
  END IF;
  v_acct := split_part(NEW.subject_id, ':', 1)::ledger_account;

  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.subject_id, 0));

  v_avail := f_available_thb(v_acct, NEW.subject_id);
  IF NEW.amount > v_avail THEN
    RAISE EXCEPTION 'ยอด THB ไม่พอ · ต้องการ % มีใช้ได้ %', NEW.amount, v_avail
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_thb_reservation_balance
  BEFORE INSERT ON reservation
  FOR EACH ROW EXECUTE FUNCTION f_thb_reservation_balance();

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

ALTER TABLE coupon_holding
  ADD CONSTRAINT fk_holding_event FOREIGN KEY (chain_event_id) REFERENCES chain_event(id);

-- ======================================================================
-- สองข้อสุดท้าย · ตรวจตอน COMMIT ไม่ใช่ตอนเขียนแต่ละแถว
--
-- ชุดของ ledger_entry ที่สมดุลมีความหมายเป็นชุด ไม่ใช่เป็นแถว
-- แถวแรกที่เขียนลงไปจะไม่สมดุลเสมอ · จะตรวจทีละแถวไม่ได้
-- CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED คือเครื่องมือที่ตรงงาน
-- ======================================================================

-- ข้อที่หนึ่ง · ledger ของแต่ละ operation ต้องรวมได้ศูนย์
CREATE OR REPLACE FUNCTION f_ledger_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_sum numeric;
BEGIN
  SELECT coalesce(sum(amount), 0) INTO v_sum
    FROM ledger_entry WHERE operation_id = NEW.operation_id;
  IF v_sum <> 0 THEN
    RAISE EXCEPTION 'ledger ของ operation % รวมได้ % ไม่ใช่ศูนย์',
      NEW.operation_id, v_sum
      USING ERRCODE = 'check_violation',
            HINT = 'เงินออกจากที่หนึ่งต้องเข้าอีกที่หนึ่งเสมอ';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_ledger_balanced
  AFTER INSERT OR UPDATE ON ledger_entry
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION f_ledger_balanced();

-- ข้อที่สอง · ยอดคงเหลือต้องเท่ากับผลรวม ledger ของบัญชีนั้น
-- เพิ่มยอดโดยไม่เขียน ledger จึงเป็นไปไม่ได้ (F4)
--
-- สำคัญ · ห้ามใช้ NEW.amount ในการเทียบ
--
--   NEW ของ constraint trigger ที่ DEFERRED คือค่าของแถว ณ ตอนที่
--   สเตตเมนต์นั้นรัน ไม่ใช่ตอน COMMIT · ถ้าแถวเดียวถูกแก้สองครั้งใน
--   transaction เดียว (ฝากเงินแล้วจ่ายเงิน) จะมี event สองตัวเข้าคิว
--   ตัวแรกถือ NEW.amount เป็นยอดหลังฝาก ซึ่งไม่ตรงกับ ledger สุดท้ายแน่ๆ
--   แล้วจะ raise ทั้งที่สถานะจริงตอน COMMIT ถูกต้อง
--
--   จึงอ่านค่าปัจจุบันจากตารางใหม่ · ทำให้การตรวจเป็น
--   "แถวตอนนี้ตรงกับ ledger ตอนนี้ไหม" ซึ่งเป็นสิ่งที่ต้องการจริง
--   และได้ผลเหมือนกันไม่ว่าจะมี event เข้าคิวกี่ตัว
CREATE OR REPLACE FUNCTION f_balance_matches_ledger() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_ledger numeric; v_current numeric;
BEGIN
  SELECT amount INTO v_current FROM thb_balance
   WHERE account = NEW.account AND account_id = NEW.account_id;
  IF NOT FOUND THEN RETURN NULL; END IF;   -- แถวถูกลบไปภายหลัง

  SELECT coalesce(sum(amount), 0) INTO v_ledger
    FROM ledger_entry
   WHERE account = NEW.account AND account_id = NEW.account_id;

  IF v_current <> v_ledger THEN
    RAISE EXCEPTION 'ยอดของบัญชี % เป็น % แต่ ledger รวมได้ %',
      NEW.account_id, v_current, v_ledger
      USING ERRCODE = 'check_violation',
            HINT = 'ยอดคงเหลือเป็น projection ของ ledger ไม่ใช่ค่าที่ตั้งเองได้';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_balance_matches_ledger
  AFTER INSERT OR UPDATE ON thb_balance
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION f_balance_matches_ledger();

COMMIT;
