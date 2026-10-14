-- =====================================================================
-- FEAT-12 · THB Deposit & Mint · migration
-- เงินบาทจริงเข้ามา แล้ว THB บน chain ถูกสร้างขึ้นเท่ากันพอดี
--
-- FEAT-10 ตั้งกฎไว้ว่า ค่าติดลบของบัญชี ISSUANCE เท่ากับ THB
-- ที่หมุนอยู่ในระบบทั้งหมด · FEAT-12 คือที่เดียวที่ ISSUANCE ขยับได้
-- ที่อื่นแตะไม่ได้เลย และ trg_issuance_only_from_mint บังคับข้อนี้
--
-- F4 · autoMintIfNeeded ของระบบเดิมเสก THB ด้วย admin key เมื่อยอดไม่พอ
--      ไม่มีเงินบาทจริงอยู่เบื้องหลัง · ไม่มีใครรู้ว่าเสกไปเท่าไร
--
--      คำถามของ feature นี้จึงไม่ใช่ "mint อย่างไร" แต่เป็น
--      "อะไรทำให้การ mint ครั้งหนึ่งถูกต้อง" และคำตอบคือ
--      ต้องมีแถว thb_deposit ที่ CONFIRMED แล้วรองรับ หนึ่งต่อหนึ่ง
--
-- เงินเข้าบัญชีธนาคาร กับ THB ปรากฏบน chain เป็นสองเรื่อง ไม่ใช่เรื่องเดียว
-- จึงเป็นสองตาราง สองสถานะ และข้ามขั้นไม่ได้
--
-- อ้างอิง  F4 · F8 · L5 · L7 · RFD 2 · RFD 14 L3
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
CREATE TYPE holder_kind AS ENUM ('MERCHANT', 'CUSTOMER');
CREATE TYPE actor_type AS ENUM ('SYSTEM', 'MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

CREATE TYPE reservation_subject AS ENUM (
  'POINT_BALANCE', 'COUPON_UNIT', 'LISTING', 'THB_BALANCE', 'ESCROW'
);

CREATE TYPE ledger_account AS ENUM (
  'CUSTOMER_THB', 'MERCHANT_THB', 'PLATFORM_THB', 'ISSUANCE'
);

-- ======================================================================
-- สถานะของการฝากเงิน
--
-- PENDING_PAYMENT → CONFIRMED → MINTED  คือเส้นทางปกติ
-- ข้ามขั้นไม่ได้ · mint จาก PENDING_PAYMENT คือการ mint ที่ไม่มีเงินรองรับ
-- ซึ่งเป็นสิ่งเดียวกับที่ F4 ทำ
-- ======================================================================
CREATE TYPE deposit_status AS ENUM (
  'PENDING_PAYMENT',  -- สร้างรายการแล้ว รอเงินเข้า
  'CONFIRMED',        -- ผู้ให้บริการยืนยันว่าเงินเข้าแล้ว · mint ได้
  'MINTED',           -- THB ถูกสร้างบน chain แล้ว
  'REVERSED',         -- ถูกตีกลับ (chargeback) หลัง mint ไปแล้ว
  'FAILED',           -- จ่ายไม่สำเร็จ · ไม่เคยมีเงินเข้า
  'EXPIRED'           -- หมดเวลารอจ่าย
);

CREATE TYPE reversal_outcome AS ENUM (
  'BURNED',         -- ยอดพอ · เผา THB คืนได้ครบ
  'MANUAL_REVIEW'   -- ยอดไม่พอ · ใช้ไปแล้ว ต้องมีคนตัดสิน
);

-- ------------------------------------------------------------ ตัวตน
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

-- ======================================================================
-- webhook ที่ผู้ให้บริการชำระเงินส่งเข้ามา · เก็บดิบไว้ทั้งก้อน
--
-- เก็บเพราะสองเหตุผล
--   1 · พิสูจน์ได้ว่าแต่ละ webhook ถูกประมวลผลครั้งเดียว
--   2 · ถ้าตีความ payload ผิด ย้อนไปอ่านของจริงได้ ไม่ต้องขอใหม่
--
-- signature ตรวจด้วย HMAC ซึ่งถูกต้องสำหรับงานนี้
--
--   ข้อควรระวัง · L7 / SPEC-001 [IK-23] ห้ามใช้ HMAC
--   แต่ข้อนั้นพูดถึง fingerprint ของ idempotency key เท่านั้น
--   ไม่ได้ห้ามใช้ HMAC ตรวจลายเซ็น webhook ซึ่งเป็นงานที่ HMAC ถูกออกแบบมาเพื่อ
--   สองเรื่องนี้คนละเรื่องกัน · อ่าน [IK-23] กว้างเกินจะได้ webhook ที่ไม่ตรวจอะไรเลย
-- ======================================================================
CREATE TABLE psp_webhook (
  id            text        PRIMARY KEY,
  provider      text        NOT NULL,
  -- id ของ event ฝั่งผู้ให้บริการ · กันการประมวลผลซ้ำเมื่อเขา retry
  provider_event_id text    NOT NULL,
  event_type    text        NOT NULL,
  raw_body      bytea       NOT NULL,
  signature     text        NOT NULL,
  signature_ok  boolean     NOT NULL,
  received_at   timestamptz NOT NULL DEFAULT now(),
  processed_at  timestamptz
);
CREATE UNIQUE INDEX uq_psp_event ON psp_webhook (provider, provider_event_id);
CREATE INDEX ix_psp_unprocessed ON psp_webhook (received_at)
  WHERE processed_at IS NULL AND signature_ok;

-- payload ดิบแก้ไม่ได้ · ถ้าแก้ได้ก็เลิกเป็นหลักฐาน
CREATE OR REPLACE FUNCTION f_psp_webhook_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.raw_body <> OLD.raw_body
     OR NEW.signature <> OLD.signature
     OR NEW.provider_event_id <> OLD.provider_event_id
     OR NEW.received_at <> OLD.received_at THEN
    RAISE EXCEPTION 'psp_webhook แก้เนื้อหาที่รับมาไม่ได้ · แก้ได้แค่ processed_at'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_psp_webhook_immutable
  BEFORE UPDATE ON psp_webhook
  FOR EACH ROW EXECUTE FUNCTION f_psp_webhook_immutable();

-- ======================================================================
-- การฝากเงิน · ข้อเท็จจริงฝั่งเงินบาท
--
-- amount_satang เป็นหน่วยเล็กสุดของเงินบาทจริง (1/100 บาท)
-- amount_base   เป็นหน่วยเล็กสุดบน chain (10^-18)
-- สองค่านี้ต้องแปลงกันได้พอดีด้วยตัวคูณคงที่ 10^16
--
-- จุดนี้คือรอยต่อระหว่างเงินจริงกับ chain และเป็นที่ที่บั๊กผิดหลักสิบยกกำลัง
-- มักเกิด · จึงไม่ปล่อยให้โค้ดคำนวณฝ่ายเดียว ฐานข้อมูลตรวจซ้ำ
-- ======================================================================
CREATE TABLE thb_deposit (
  id             text           PRIMARY KEY,
  holder_kind    holder_kind    NOT NULL,
  holder_id      text           NOT NULL,
  provider       text           NOT NULL,
  -- reference ของผู้ให้บริการ · คือ idempotency key ตัวจริงของ feature นี้
  -- เราไม่ได้เลือกค่านี้เอง · มันมาจากข้างนอก
  provider_ref   text           NOT NULL,
  amount_satang  bigint         NOT NULL CHECK (amount_satang > 0),
  amount_base    numeric(78,0)  NOT NULL CHECK (amount_base > 0),
  status         deposit_status NOT NULL DEFAULT 'PENDING_PAYMENT',
  webhook_id     text           REFERENCES psp_webhook(id),
  created_at     timestamptz    NOT NULL DEFAULT now(),
  confirmed_at   timestamptz,
  minted_at      timestamptz,
  expires_at     timestamptz    NOT NULL DEFAULT now() + interval '24 hours',
  CONSTRAINT ck_dep_confirmed
    CHECK ((confirmed_at IS NOT NULL) = (status IN ('CONFIRMED','MINTED','REVERSED'))),
  CONSTRAINT ck_dep_minted
    CHECK ((minted_at IS NOT NULL) = (status IN ('MINTED','REVERSED'))),
  -- ยืนยันแล้วต้องมี webhook อ้างอิง · ยืนยันเองลอยๆ ไม่ได้
  CONSTRAINT ck_dep_needs_webhook
    CHECK (status IN ('PENDING_PAYMENT','FAILED','EXPIRED') OR webhook_id IS NOT NULL)
);
CREATE UNIQUE INDEX uq_deposit_provider_ref ON thb_deposit (provider, provider_ref);
CREATE INDEX ix_deposit_holder ON thb_deposit (holder_kind, holder_id, created_at);
CREATE INDEX ix_deposit_mintable ON thb_deposit (confirmed_at) WHERE status = 'CONFIRMED';

-- 1 สตางค์ = 10^16 base units · 1 บาท = 10^18
CREATE OR REPLACE FUNCTION f_satang_to_base(p_satang bigint) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$ SELECT p_satang::numeric * 10000000000000000 $$;

CREATE OR REPLACE FUNCTION f_deposit_amount_exact() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.amount_base <> f_satang_to_base(NEW.amount_satang) THEN
    RAISE EXCEPTION 'ยอดไม่ตรงกัน · % สตางค์ ต้องเป็น % base units ไม่ใช่ %',
      NEW.amount_satang, f_satang_to_base(NEW.amount_satang), NEW.amount_base
      USING ERRCODE = 'check_violation',
            HINT = 'ตัวคูณคือ 10^16 · 1 บาท = 100 สตางค์ = 10^18 base units';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_deposit_amount_exact
  BEFORE INSERT OR UPDATE ON thb_deposit
  FOR EACH ROW EXECUTE FUNCTION f_deposit_amount_exact();

-- ======================================================================
-- เส้นทางสถานะของการฝาก · ข้ามขั้นไม่ได้
--
-- mint จาก PENDING_PAYMENT คือการสร้าง THB ที่ไม่มีเงินรองรับ
-- ซึ่งเป็นสิ่งเดียวกับที่ F4 ทำ · ปิดที่นี่
-- ======================================================================
CREATE OR REPLACE FUNCTION f_deposit_status_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- ยอดเงินแก้ไม่ได้หลังยืนยัน · ยืนยัน 100 แล้ว mint 1000 ไม่ได้
  --
  -- ข้อนี้ต้องอยู่ "ก่อน" การคืนค่าเมื่อสถานะไม่เปลี่ยน
  -- เพราะ UPDATE ที่แก้แต่ยอดโดยไม่แตะสถานะ จะข้ามทุกอย่างใต้บรรทัดนั้นไป
  -- ครั้งแรกเขียนไว้ท้ายฟังก์ชัน และ T15 จับได้ว่าแก้ยอดผ่านฉลุย
  IF OLD.status <> 'PENDING_PAYMENT'
     AND (NEW.amount_satang <> OLD.amount_satang
          OR NEW.amount_base <> OLD.amount_base) THEN
    RAISE EXCEPTION 'การฝาก % ยืนยันแล้ว แก้ยอดไม่ได้', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.status = NEW.status THEN RETURN NEW; END IF;

  IF NOT (
       (OLD.status = 'PENDING_PAYMENT' AND NEW.status IN ('CONFIRMED','FAILED','EXPIRED'))
    OR (OLD.status = 'CONFIRMED'       AND NEW.status = 'MINTED')
    OR (OLD.status = 'MINTED'          AND NEW.status = 'REVERSED')
  ) THEN
    RAISE EXCEPTION 'การฝาก % เปลี่ยนสถานะจาก % ไป % ไม่ได้',
      OLD.id, OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'CONFIRMED' AND NEW.confirmed_at IS NULL THEN
    NEW.confirmed_at := now();
  END IF;
  IF NEW.status = 'MINTED' AND NEW.minted_at IS NULL THEN
    NEW.minted_at := now();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_deposit_status_transition
  BEFORE UPDATE ON thb_deposit
  FOR EACH ROW EXECUTE FUNCTION f_deposit_status_transition();

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
                 CHECK (actor_scope ~ '^(merchant|customer|admin|anon|system):.+$'),
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

-- การฝากหนึ่งรายการมีงาน mint ค้างได้ทีละงานเดียว
CREATE UNIQUE INDEX uq_mint_inflight
  ON operation (subject_id)
  WHERE kind = 'THB_MINT' AND status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

-- mint = หนึ่ง tx · ไม่ใช่สองหรือสาม
--
-- pack ก่อนๆ มีสองถึงสามขั้นเพราะงานนั้นต้องการจริง
-- การ mint ต้องการ tx เดียว · เติมขั้นให้ดูเข้าชุดกับ pack อื่นคือการทำผิด
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

-- ======================================================================
-- การ mint · ข้อเท็จจริงฝั่ง chain
--
-- คีย์เป็น deposit_id โดยตั้งใจ · การฝากหนึ่งรายการ mint ได้ครั้งเดียว
-- ไม่ต้องมี index เพิ่ม ไม่ต้องเขียน trigger · primary key ทำงานนี้เอง
-- ======================================================================
CREATE TABLE thb_mint (
  deposit_id   text          PRIMARY KEY REFERENCES thb_deposit(id),
  operation_id text          NOT NULL REFERENCES operation(id),
  amount_base  numeric(78,0) NOT NULL CHECK (amount_base > 0),
  to_account   ledger_account NOT NULL,
  to_account_id text         NOT NULL,
  chain_event_id text        REFERENCES chain_event(id),
  tx_hash      bytea         CHECK (tx_hash IS NULL OR octet_length(tx_hash) = 32),
  minted_block bigint        CHECK (minted_block IS NULL OR minted_block > 0),
  applied_at   timestamptz,
  CONSTRAINT ck_mint_applied
    CHECK ((applied_at IS NULL) = (chain_event_id IS NULL))
);
CREATE UNIQUE INDEX uq_mint_operation ON thb_mint (operation_id);

-- ======================================================================
-- mint ได้เฉพาะจากการฝากที่ CONFIRMED แล้ว และยอดต้องตรงกันพอดี
--
-- นี่คือประโยคที่ตอบคำถามของ feature นี้
-- "อะไรทำให้การ mint ครั้งหนึ่งถูกต้อง" → แถวนี้
-- ======================================================================
CREATE OR REPLACE FUNCTION f_mint_requires_confirmed_deposit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_st deposit_status; v_amt numeric; v_hk holder_kind; v_hid text; v_expect ledger_account;
BEGIN
  SELECT status, amount_base, holder_kind, holder_id
    INTO v_st, v_amt, v_hk, v_hid
    FROM thb_deposit WHERE id = NEW.deposit_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบการฝาก %', NEW.deposit_id USING ERRCODE = 'check_violation';
  END IF;

  IF v_st <> 'CONFIRMED' THEN
    RAISE EXCEPTION 'การฝาก % อยู่สถานะ % · mint ไม่ได้', NEW.deposit_id, v_st
      USING ERRCODE = 'check_violation',
            HINT = 'mint ได้เฉพาะจากการฝากที่ผู้ให้บริการยืนยันแล้ว';
  END IF;

  IF NEW.amount_base <> v_amt THEN
    RAISE EXCEPTION 'ยอด mint % ไม่เท่ากับยอดที่ฝาก %', NEW.amount_base, v_amt
      USING ERRCODE = 'check_violation';
  END IF;

  -- ปลายทางต้องเป็นเจ้าของการฝาก ไม่ใช่ใครก็ได้
  v_expect := CASE v_hk WHEN 'MERCHANT' THEN 'MERCHANT_THB'::ledger_account
                        ELSE 'CUSTOMER_THB'::ledger_account END;
  IF NEW.to_account <> v_expect
     OR NEW.to_account_id <> v_expect::text || ':' || v_hid THEN
    RAISE EXCEPTION 'ปลายทาง %:% ไม่ใช่เจ้าของการฝาก (ควรเป็น %:%)',
      NEW.to_account, NEW.to_account_id, v_expect, v_expect::text || ':' || v_hid
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_mint_requires_confirmed_deposit
  BEFORE INSERT ON thb_mint
  FOR EACH ROW EXECUTE FUNCTION f_mint_requires_confirmed_deposit();

-- ============================================== เงินและสมุดบัญชี (FEAT-10)
CREATE TABLE thb_balance (
  account    ledger_account NOT NULL,
  account_id text           NOT NULL,
  amount     numeric(78,0)  NOT NULL DEFAULT 0,
  updated_at timestamptz    NOT NULL DEFAULT now(),
  PRIMARY KEY (account, account_id),
  CONSTRAINT ck_balance_sign CHECK (amount >= 0 OR account = 'ISSUANCE')
);

CREATE TABLE ledger_entry (
  id           text           PRIMARY KEY,
  operation_id text           NOT NULL REFERENCES operation(id),
  entry_seq    integer        NOT NULL CHECK (entry_seq >= 1),
  account      ledger_account NOT NULL,
  account_id   text           NOT NULL,
  asset        text           NOT NULL DEFAULT 'THB' CHECK (asset = 'THB'),
  amount       numeric(78,0)  NOT NULL CHECK (amount <> 0),
  memo         text,
  created_at   timestamptz    NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_ledger_seq ON ledger_entry (operation_id, entry_seq);
CREATE INDEX ix_ledger_account ON ledger_entry (account, account_id, created_at);
CREATE INDEX ix_ledger_issuance ON ledger_entry (created_at) WHERE account = 'ISSUANCE';

-- ======================================================================
-- กฎที่สำคัญที่สุดของ pack นี้
--
-- ISSUANCE ขยับได้จาก operation ที่ kind = THB_MINT เท่านั้น
--
-- FEAT-10 ตั้งกฎว่า ลบ ISSUANCE = THB ที่หมุนอยู่ในระบบทั้งหมด
-- ถ้าที่อื่นแตะ ISSUANCE ได้ กฎนั้นก็ไม่มีความหมาย
-- การซื้อขายเคลื่อนเงินระหว่างบัญชี · ไม่สร้างและไม่ทำลาย
-- มีแต่ที่นี่ที่สร้างและทำลายได้ และต้องมีเงินบาทจริงรองรับทุกครั้ง
-- ======================================================================
CREATE OR REPLACE FUNCTION f_issuance_only_from_mint() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_kind operation_kind;
BEGIN
  IF NEW.account <> 'ISSUANCE' THEN RETURN NEW; END IF;

  SELECT kind INTO v_kind FROM operation WHERE id = NEW.operation_id;
  IF v_kind <> 'THB_MINT' THEN
    RAISE EXCEPTION 'operation kind % แตะบัญชี ISSUANCE ไม่ได้', v_kind
      USING ERRCODE = 'check_violation',
            HINT = 'THB เข้าและออกจากระบบได้ที่ FEAT-12 เท่านั้น · ที่อื่นเคลื่อนย้ายได้แต่สร้างไม่ได้';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_issuance_only_from_mint
  BEFORE INSERT OR UPDATE ON ledger_entry
  FOR EACH ROW EXECUTE FUNCTION f_issuance_only_from_mint();

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
-- การตีกลับ · ส่วนที่ตอบยากที่สุดของ feature นี้
--
-- เงินบาทถูกตีกลับ แต่ THB ถูก mint ไปแล้ว และอาจถูกใช้ซื้อของไปแล้ว
-- จะ "ยกเลิก" ย้อนหลังไม่ได้ · ของที่ซื้อไปแล้วอยู่ในมือคนอื่น
--
-- ทางที่เลือก
--   ยอดที่ใช้ได้ยังพอ  → เผา THB คืน · ledger สมดุล · จบ
--   ยอดไม่พอ          → MANUAL_REVIEW · ไม่แตะยอด ไม่แต่งตัวเลข
--
-- ทางที่ไม่เลือก และเหตุผล
--   ปล่อยยอดติดลบ     ck_balance_sign ไม่ยอม และยอดติดลบจะไหลไปทุกที่
--   เผาเท่าที่มี        ledger จะไม่สมดุล · ส่วนต่างจะหายไปเงียบๆ แบบ F8
--   เสกเงินมาเผา       คือ F4 กลับหัว
--
-- การยอมรับว่าบางกรณีต้องมีคนตัดสิน ถูกกว่าการแกล้งว่าแก้ได้อัตโนมัติ
-- ======================================================================
CREATE TABLE deposit_reversal (
  id            text             PRIMARY KEY,
  deposit_id    text             NOT NULL REFERENCES thb_deposit(id),
  webhook_id    text             NOT NULL REFERENCES psp_webhook(id),
  operation_id  text             NOT NULL REFERENCES operation(id),
  amount_base   numeric(78,0)    NOT NULL CHECK (amount_base > 0),
  available_at_reversal numeric(78,0) NOT NULL CHECK (available_at_reversal >= 0),
  outcome       reversal_outcome NOT NULL,
  note          text,
  created_at    timestamptz      NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_reversal_deposit ON deposit_reversal (deposit_id);
CREATE INDEX ix_reversal_review ON deposit_reversal (created_at)
  WHERE outcome = 'MANUAL_REVIEW';

CREATE OR REPLACE FUNCTION f_reversal_outcome_matches_balance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_st deposit_status; v_amt numeric;
BEGIN
  SELECT status, amount_base INTO v_st, v_amt
    FROM thb_deposit WHERE id = NEW.deposit_id;

  -- ตีกลับได้เฉพาะการฝากที่ mint ไปแล้ว
  IF v_st <> 'MINTED' THEN
    RAISE EXCEPTION 'การฝาก % อยู่สถานะ % · ตีกลับไม่ได้', NEW.deposit_id, v_st
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.amount_base <> v_amt THEN
    RAISE EXCEPTION 'ยอดตีกลับ % ไม่เท่ากับยอดที่ฝาก %', NEW.amount_base, v_amt
      USING ERRCODE = 'check_violation';
  END IF;

  -- ผลลัพธ์ต้องตรงกับยอดที่มีจริงตอนนั้น · เลือกเองไม่ได้
  IF NEW.outcome = 'BURNED' AND NEW.available_at_reversal < NEW.amount_base THEN
    RAISE EXCEPTION 'ยอดที่ใช้ได้ % ไม่พอเผา % · ต้องเป็น MANUAL_REVIEW',
      NEW.available_at_reversal, NEW.amount_base
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.outcome = 'MANUAL_REVIEW' AND NEW.available_at_reversal >= NEW.amount_base THEN
    RAISE EXCEPTION 'ยอดที่ใช้ได้ % พอเผา % · ต้องเป็น BURNED ไม่ใช่ MANUAL_REVIEW',
      NEW.available_at_reversal, NEW.amount_base
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_reversal_outcome_matches_balance
  BEFORE INSERT ON deposit_reversal
  FOR EACH ROW EXECUTE FUNCTION f_reversal_outcome_matches_balance();

-- ----------------------------- สองกฎที่ตรวจตอน COMMIT (ยกมาจาก FEAT-10)
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

-- ห้ามใช้ NEW.amount · ดูเหตุผลเต็มใน README ของ FEAT-10
-- NEW ของ deferred trigger คือค่า ณ ตอนที่สเตตเมนต์รัน ไม่ใช่ตอน COMMIT
CREATE OR REPLACE FUNCTION f_balance_matches_ledger() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_ledger numeric; v_current numeric;
BEGIN
  SELECT amount INTO v_current FROM thb_balance
   WHERE account = NEW.account AND account_id = NEW.account_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

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
