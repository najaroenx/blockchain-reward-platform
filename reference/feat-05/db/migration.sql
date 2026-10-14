-- =====================================================================
-- FEAT-05 · Transfer Point · migration
-- ร้านโอน point ให้ลูกค้า · ยอดเก็บเป็น bucket ต่อ epoch เพราะ point หมดอายุได้
--
-- เรื่องที่ต่างจากชุดก่อน
--   1 · ยอด point บวกกันได้ จึงใช้ partial unique index แบบ COUPON_UNIT ไม่ได้
--       ความถูกต้องมาจาก trigger ที่ตรวจยอดคงเหลือ + advisory lock แทน
--   2 · โอนเป็นชุดคือ operation เดียวหลาย step · หนึ่ง step = หนึ่ง tx
--
-- อ้างอิง  RFD 2 §3.3 · RFD 9 · RFD 10 · RFD 14 L3
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
CREATE TYPE point_type_status AS ENUM ('REQUESTED', 'LIVE', 'FAILED', 'RETIRED');
CREATE TYPE holder_kind AS ENUM ('MERCHANT', 'CUSTOMER');
CREATE TYPE actor_type AS ENUM ('SYSTEM', 'MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

-- RFD 9 · subject ของการจอง · ชนิดที่เป็นของชิ้นเดียวกับชนิดที่เป็นยอด
-- ถูกบังคับด้วยกลไกคนละแบบ ดู uq_reservation_exclusive ด้านล่าง
CREATE TYPE reservation_subject AS ENUM (
  'POINT_BALANCE', 'COUPON_UNIT', 'LISTING', 'THB_BALANCE', 'ESCROW'
);

CREATE TYPE ledger_direction AS ENUM ('DEBIT', 'CREDIT');

-- ------------------------------------------------- ตัวตน (FEAT-01, 04)
CREATE TABLE merchant (
  id         text PRIMARY KEY,
  name       text            NOT NULL,
  status     merchant_status NOT NULL DEFAULT 'PENDING',
  created_at timestamptz     NOT NULL DEFAULT now()
);

CREATE TABLE customer (
  id         text PRIMARY KEY,
  tel_hash   bytea       NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_customer_tel ON customer (tel_hash);

CREATE TABLE wallet (
  id         text PRIMARY KEY,
  address    bytea       NOT NULL CHECK (octet_length(address) = 20),
  key_ref    text        NOT NULL,
  owner_kind text        NOT NULL CHECK (owner_kind IN ('MERCHANT','CUSTOMER','PLATFORM')),
  owner_id   text        NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_wallet_address ON wallet (address);
CREATE UNIQUE INDEX uq_wallet_owner   ON wallet (owner_kind, owner_id);

CREATE TABLE signer (
  address    bytea PRIMARY KEY CHECK (octet_length(address) = 20),
  key_ref    text   NOT NULL,
  next_nonce bigint NOT NULL DEFAULT 0 CHECK (next_nonce >= 0),
  enabled    boolean NOT NULL DEFAULT true
);

CREATE TABLE point_type (
  id          text PRIMARY KEY,
  merchant_id text              NOT NULL REFERENCES merchant(id),
  name        text              NOT NULL,
  symbol      text              NOT NULL,
  decimals    smallint          NOT NULL CHECK (decimals BETWEEN 0 AND 30),
  status      point_type_status NOT NULL DEFAULT 'REQUESTED',
  created_at  timestamptz       NOT NULL DEFAULT now()
);

CREATE TABLE point_type_chain (
  point_type_id    text PRIMARY KEY REFERENCES point_type(id),
  contract_address bytea       NOT NULL CHECK (octet_length(contract_address) = 20),
  genesis_at       timestamptz NOT NULL,
  epoch_seconds    integer     NOT NULL CHECK (epoch_seconds > 0),
  validity_epochs  integer     NOT NULL CHECK (validity_epochs > 0)
);
CREATE UNIQUE INDEX uq_point_chain_address ON point_type_chain (contract_address);

-- =============================================== ยอด point แบบ bucket
-- RFD 10 · point หมดอายุโดยไม่มี event บน chain
-- จึงไม่เก็บ "ยอดคงเหลือ" เป็นตัวเลขเดียว แต่เก็บแยกตาม epoch ที่ได้รับมา
-- ยอดที่ใช้ได้ = ผลรวมของ bucket ที่ยังไม่หมดอายุ · คำนวณตอน query
--
-- expires_at คำนวณจาก genesis_at + epoch_seconds ของ contract
-- ซึ่งเป็นค่าคงที่ จึง rebuild projection แล้วได้ค่าเดิมเสมอ
CREATE TABLE point_balance_bucket (
  id            text PRIMARY KEY,
  point_type_id text          NOT NULL REFERENCES point_type(id),
  holder_kind   holder_kind   NOT NULL,
  holder_id     text          NOT NULL,
  epoch_index   integer       NOT NULL CHECK (epoch_index >= 0),
  -- RFD 14 · base units เสมอ
  amount        numeric(78,0) NOT NULL CHECK (amount >= 0),
  received_at   timestamptz   NOT NULL,
  expires_at    timestamptz   NOT NULL,
  updated_at    timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_bucket_expiry CHECK (expires_at > received_at)
);
-- หนึ่ง bucket ต่อ (ผู้ถือ, point type, epoch) · ยอดในรอบเดียวกันรวมกัน
CREATE UNIQUE INDEX uq_bucket
  ON point_balance_bucket (point_type_id, holder_kind, holder_id, epoch_index);
-- index สำหรับคิดยอดที่ใช้ได้ · ครอบเฉพาะ bucket ที่ยังมียอด
CREATE INDEX ix_bucket_live
  ON point_balance_bucket (point_type_id, holder_kind, holder_id, expires_at)
  WHERE amount > 0;

-- derive จาก chain_event · double entry
CREATE TABLE ledger_entry (
  id             text PRIMARY KEY,
  operation_id   text,
  point_type_id  text             NOT NULL REFERENCES point_type(id),
  holder_kind    holder_kind      NOT NULL,
  holder_id      text             NOT NULL,
  direction      ledger_direction NOT NULL,
  amount         numeric(78,0)    NOT NULL CHECK (amount > 0),
  chain_event_id text,
  created_at     timestamptz      NOT NULL DEFAULT now()
);
CREATE INDEX ix_ledger_holder ON ledger_entry (point_type_id, holder_kind, holder_id);
CREATE INDEX ix_ledger_operation ON ledger_entry (operation_id);

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

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);
ALTER TABLE ledger_entry
  ADD CONSTRAINT fk_ledger_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

-- โอนเป็นชุด = หนึ่ง operation หลาย step · หนึ่ง step = หนึ่ง tx
CREATE TABLE operation_step (
  id             text PRIMARY KEY,
  operation_id   text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  step_index     integer     NOT NULL CHECK (step_index >= 1),
  name           text        NOT NULL,
  -- จำนวนผู้รับใน tx นี้ · ใช้ตรวจว่าแบ่ง chunk ครบ
  recipient_count integer    NOT NULL DEFAULT 1 CHECK (recipient_count BETWEEN 1 AND 100),
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
  -- สำหรับ POINT_BALANCE รูปแบบคือ  <point_type_id>|<holder_kind>|<holder_id>
  subject_id   text                NOT NULL,
  amount       numeric(78,0)       NOT NULL CHECK (amount > 0),
  created_at   timestamptz         NOT NULL DEFAULT now(),
  released_at  timestamptz
);

-- RFD 9 Q4 · index นี้แคบลงเหลือเฉพาะชนิดที่เป็น "ของชิ้นเดียว"
-- ยอด point บวกกันได้ · ร้านโอนให้ลูกค้าหลายคนพร้อมกันต้องทำได้
-- ถ้าคง POINT_BALANCE ไว้ในนี้ ร้านจะโอนได้ครั้งละหนึ่งรายการเท่านั้น
CREATE UNIQUE INDEX uq_reservation_exclusive
  ON reservation (subject_type, subject_id)
  WHERE released_at IS NULL
    AND subject_type IN ('COUPON_UNIT','LISTING','ESCROW');

CREATE INDEX ix_reservation_open
  ON reservation (subject_type, subject_id) WHERE released_at IS NULL;

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

-- ============================== ยอดคงเหลือที่ใช้ได้ · ความถูกต้องของ point
-- ยอดที่ใช้ได้ = ผลรวม bucket ที่ยังไม่หมดอายุ − reservation ที่ยังไม่ปล่อย
CREATE OR REPLACE FUNCTION f_available_points(
  p_point_type_id text, p_holder_kind holder_kind, p_holder_id text, p_as_of timestamptz
) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE((
    SELECT sum(amount) FROM point_balance_bucket
     WHERE point_type_id = p_point_type_id
       AND holder_kind   = p_holder_kind
       AND holder_id     = p_holder_id
       AND expires_at    > p_as_of
  ), 0)
  - COALESCE((
    SELECT sum(amount) FROM reservation
     WHERE subject_type = 'POINT_BALANCE'
       AND released_at IS NULL
       AND subject_id = p_point_type_id || '|' || p_holder_kind::text || '|' || p_holder_id
  ), 0)
$$;

-- จองยอดเกินที่มีไม่ได้
-- ไม่ใช้ unique index เพราะยอดบวกกันได้ · ใช้ advisory lock + ตรวจผลรวมแทน
-- lock ครอบเฉพาะ subject เดียว จึงไม่กันการโอนของ point type อื่นหรือร้านอื่น
CREATE OR REPLACE FUNCTION f_check_point_reservation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_pt text; v_kind_text text; v_kind holder_kind; v_holder text; v_avail numeric;
BEGIN
  IF NEW.subject_type <> 'POINT_BALANCE' THEN RETURN NEW; END IF;

  v_pt        := split_part(NEW.subject_id, '|', 1);
  v_kind_text := split_part(NEW.subject_id, '|', 2);
  v_holder    := split_part(NEW.subject_id, '|', 3);

  -- ตรวจรูปแบบให้ครบก่อน cast · ไม่งั้นจะได้ error 22P02 ที่อ่านไม่รู้เรื่อง
  IF v_pt = '' OR v_holder = '' OR v_kind_text NOT IN ('MERCHANT','CUSTOMER') THEN
    RAISE EXCEPTION 'subject_id ของ POINT_BALANCE ต้องเป็น <point_type_id>|<holder_kind>|<holder_id>'
      USING ERRCODE = 'check_violation';
  END IF;
  v_kind := v_kind_text::holder_kind;

  -- serialize เฉพาะ subject นี้จนจบ transaction
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.subject_id, 0));

  v_avail := f_available_points(v_pt, v_kind, v_holder, now());
  IF NEW.amount > v_avail THEN
    RAISE EXCEPTION 'ยอดไม่พอ · ต้องการ % แต่ใช้ได้ %', NEW.amount, v_avail
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_point_reservation_balance
  BEFORE INSERT ON reservation
  FOR EACH ROW EXECUTE FUNCTION f_check_point_reservation();

-- RFD 9 · ปล่อยจองได้เมื่องานจบแล้วเท่านั้น
-- ปล่อยตอน SUBMITTED คือการบอกว่ายอดว่างทั้งที่ tx ยังอาจสำเร็จ
-- MANUAL_REVIEW ก็ยังปล่อยไม่ได้ ต้องให้คนตัดสินก่อนว่าจบทางไหน
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
