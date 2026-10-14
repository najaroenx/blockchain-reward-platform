-- =====================================================================
-- FEAT-06 · Point Balance · bucket + expiry query
-- ชุดนี้เป็นฝั่งอ่านล้วน · ไม่มี operation ไม่มี outbox ไม่มี chain tx
--
-- หลักเดียวที่ทั้งชุดตั้งอยู่บน
--   ทุก query รับ as_of เป็นพารามิเตอร์ · ไม่เรียก now() ข้างใน
--   คำตอบจึงเป็นฟังก์ชันบริสุทธิ์ของ (ข้อมูล, เวลา) · ทดสอบได้ · ทำซ้ำได้
--
-- อ้างอิง  RFD 6 · RFD 10 · RFD 14 L3
-- รันบน PostgreSQL 16 ได้ตรงๆ
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------- enum
CREATE TYPE holder_kind AS ENUM ('MERCHANT', 'CUSTOMER');
CREATE TYPE point_type_status AS ENUM ('REQUESTED', 'LIVE', 'FAILED', 'RETIRED');
CREATE TYPE reservation_subject AS ENUM (
  'POINT_BALANCE', 'COUPON_UNIT', 'LISTING', 'THB_BALANCE', 'ESCROW'
);

-- ------------------------------------------------ ตัวตน (FEAT-01 · 04)
CREATE TABLE merchant (
  id         text PRIMARY KEY,
  name       text        NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE customer (
  id         text PRIMARY KEY,
  tel_hash   bytea       NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_customer_tel ON customer (tel_hash);

CREATE TABLE point_type (
  id          text PRIMARY KEY,
  merchant_id text              NOT NULL REFERENCES merchant(id),
  name        text              NOT NULL,
  symbol      text              NOT NULL,
  decimals    smallint          NOT NULL CHECK (decimals BETWEEN 0 AND 30),
  status      point_type_status NOT NULL DEFAULT 'REQUESTED'
);

CREATE TABLE point_type_chain (
  point_type_id    text PRIMARY KEY REFERENCES point_type(id),
  contract_address bytea       NOT NULL CHECK (octet_length(contract_address) = 20),
  genesis_at       timestamptz NOT NULL,
  epoch_seconds    integer     NOT NULL CHECK (epoch_seconds > 0),
  validity_epochs  integer     NOT NULL CHECK (validity_epochs > 0)
);

-- ============================================================= ยอด
-- RFD 10 · ไม่มีคอลัมน์ "ยอดคงเหลือ" ที่ไหน · คิดตอน query ทุกครั้ง
CREATE TABLE point_balance_bucket (
  id            text PRIMARY KEY,
  point_type_id text          NOT NULL REFERENCES point_type(id),
  holder_kind   holder_kind   NOT NULL,
  holder_id     text          NOT NULL,
  epoch_index   integer       NOT NULL CHECK (epoch_index >= 0),
  amount        numeric(78,0) NOT NULL CHECK (amount >= 0),
  received_at   timestamptz   NOT NULL,
  expires_at    timestamptz   NOT NULL,
  updated_at    timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_bucket_expiry CHECK (expires_at > received_at)
);
CREATE UNIQUE INDEX uq_bucket
  ON point_balance_bucket (point_type_id, holder_kind, holder_id, epoch_index);

-- index ที่ query ยอดต้องใช้
-- เรียงคอลัมน์ตามรูปของ query · สามตัวแรกเป็น equality สุดท้ายเป็น range
-- INCLUDE (amount) ทำให้ index-only scan ได้ · ไม่ต้องแตะ heap
CREATE INDEX ix_bucket_live
  ON point_balance_bucket (point_type_id, holder_kind, holder_id, expires_at)
  INCLUDE (amount)
  WHERE amount > 0;

CREATE TABLE reservation (
  id           text PRIMARY KEY,
  subject_type reservation_subject NOT NULL,
  subject_id   text                NOT NULL,
  amount       numeric(78,0)       NOT NULL CHECK (amount > 0),
  created_at   timestamptz         NOT NULL DEFAULT now(),
  released_at  timestamptz
);
CREATE INDEX ix_reservation_open
  ON reservation (subject_type, subject_id) INCLUDE (amount)
  WHERE released_at IS NULL;

-- ===================================================== ความทันของข้อมูล
-- projection ตามหลัง chain เสมอ · ผู้เรียกต้องรู้ว่าตามหลังแค่ไหน
-- ไม่งั้นจะเข้าใจผิดว่ายอดที่เห็นคือยอดล่าสุดบน chain
CREATE TABLE projection_watermark (
  id              boolean PRIMARY KEY DEFAULT true CHECK (id),  -- มีได้แถวเดียว
  last_block      bigint      NOT NULL CHECK (last_block >= 0),
  last_block_at   timestamptz NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE indexer_cursor (
  contract_address bytea PRIMARY KEY CHECK (octet_length(contract_address) = 20),
  last_block       bigint      NOT NULL CHECK (last_block >= 0),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- projector ตามหลัง indexer เสมอ · ย้อนกลับไม่ได้
CREATE OR REPLACE FUNCTION f_watermark_monotonic() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.last_block < OLD.last_block THEN
    RAISE EXCEPTION 'watermark ถอยหลังไม่ได้ · เดิม % ใหม่ %', OLD.last_block, NEW.last_block
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_watermark_monotonic
  BEFORE UPDATE ON projection_watermark
  FOR EACH ROW EXECUTE FUNCTION f_watermark_monotonic();

-- ================================================ การแจ้งเตือนก่อนหมดอายุ
-- ไม่มี cron ที่ไล่ลดยอด · มีแค่ query หา bucket ที่ใกล้หมดอายุ
-- ตารางนี้เก็บว่าเคยแจ้งไปแล้วหรือยัง เพื่อไม่ให้แจ้งซ้ำ
CREATE TABLE expiry_notice (
  id             text PRIMARY KEY,
  bucket_id      text        NOT NULL REFERENCES point_balance_bucket(id) ON DELETE CASCADE,
  -- แจ้งล่วงหน้ากี่วัน · ค่าที่อนุญาตถูกจำกัดไว้ให้ตรงกับนโยบาย
  threshold_days integer     NOT NULL CHECK (threshold_days IN (30, 7, 1)),
  notified_at    timestamptz NOT NULL DEFAULT now(),
  channel        text        NOT NULL CHECK (channel IN ('PUSH','EMAIL','SMS'))
);
-- แจ้งซ้ำที่ระดับเดียวกันของ bucket เดิมเป็นไปไม่ได้
CREATE UNIQUE INDEX uq_notice ON expiry_notice (bucket_id, threshold_days);

-- แจ้งเตือน bucket ที่หมดอายุไปแล้วไม่ได้
CREATE OR REPLACE FUNCTION f_notice_not_expired() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_exp timestamptz;
BEGIN
  SELECT expires_at INTO v_exp FROM point_balance_bucket WHERE id = NEW.bucket_id;
  IF v_exp <= NEW.notified_at THEN
    RAISE EXCEPTION 'bucket % หมดอายุไปแล้ว แจ้งเตือนล่วงหน้าไม่ได้', NEW.bucket_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_notice_not_expired
  BEFORE INSERT ON expiry_notice
  FOR EACH ROW EXECUTE FUNCTION f_notice_not_expired();

-- =====================================================================
-- ฟังก์ชันอ่าน · ทุกตัวรับ as_of · ไม่มีตัวไหนเรียก now() ข้างใน
-- =====================================================================

-- ยอดรวมที่ยังไม่หมดอายุ ณ เวลาที่กำหนด
CREATE OR REPLACE FUNCTION f_unexpired_total(
  p_point_type_id text, p_holder_kind holder_kind, p_holder_id text, p_as_of timestamptz
) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(amount), 0) FROM point_balance_bucket
   WHERE point_type_id = p_point_type_id
     AND holder_kind   = p_holder_kind
     AND holder_id     = p_holder_id
     AND amount > 0
     AND expires_at > p_as_of
$$;

-- ยอดที่ถูกกันไว้ระหว่างรอ chain
CREATE OR REPLACE FUNCTION f_reserved_total(
  p_point_type_id text, p_holder_kind holder_kind, p_holder_id text
) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(amount), 0) FROM reservation
   WHERE subject_type = 'POINT_BALANCE'
     AND released_at IS NULL
     AND subject_id = p_point_type_id || '|' || p_holder_kind::text || '|' || p_holder_id
$$;

-- ยอดที่ใช้ได้ · ติดลบไม่ได้แม้ reservation จะค้างอยู่มากกว่ายอด
CREATE OR REPLACE FUNCTION f_available_points(
  p_point_type_id text, p_holder_kind holder_kind, p_holder_id text, p_as_of timestamptz
) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT greatest(
    f_unexpired_total(p_point_type_id, p_holder_kind, p_holder_id, p_as_of)
    - f_reserved_total(p_point_type_id, p_holder_kind, p_holder_id), 0)
$$;

-- ยอดที่จะหมดอายุในแต่ละวัน · ใช้ทำกราฟและใช้เลือกคนที่ต้องแจ้งเตือน
CREATE OR REPLACE FUNCTION f_expiry_forecast(
  p_point_type_id text, p_holder_kind holder_kind, p_holder_id text,
  p_as_of timestamptz, p_horizon_days integer
) RETURNS TABLE (expires_on date, amount numeric)
LANGUAGE sql STABLE AS $$
  SELECT (expires_at AT TIME ZONE 'UTC')::date AS expires_on, sum(amount)
    FROM point_balance_bucket
   WHERE point_type_id = p_point_type_id
     AND holder_kind   = p_holder_kind
     AND holder_id     = p_holder_id
     AND amount > 0
     AND expires_at >  p_as_of
     AND expires_at <= p_as_of + make_interval(days => p_horizon_days)
   GROUP BY 1 ORDER BY 1
$$;

-- ยอดที่หมดอายุไปแล้วสะสม · เป็น query ไม่ใช่ตาราง
CREATE OR REPLACE FUNCTION f_expired_total(
  p_point_type_id text, p_as_of timestamptz
) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(amount), 0) FROM point_balance_bucket
   WHERE point_type_id = p_point_type_id
     AND expires_at <= p_as_of
$$;

COMMIT;
