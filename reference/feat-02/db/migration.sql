-- =====================================================================
-- FEAT-02 · Customer Register + OTP · migration
-- ลูกค้าสมัครด้วยเบอร์โทร ยืนยันด้วย OTP แล้วได้ wallet
--
-- pack นี้มีข้อเท็จจริงจากระบบเดิมมากที่สุดในทั้งชุด · ห้าข้อ
--
--   F6   createOTP.handler.ts คืนค่า OTP กลับมาใน response
--        พร้อมคอมเมนต์ // For testing purposes
--
--   F7   templink.controller.ts endpoint send-otp เขียนทับเบอร์โทร
--        ด้วยค่าจาก body
--
--   F10  ระบบถอดรหัส private key ของลูกค้าเองเพื่อเซ็น
--
--   F12  auth.service.ts register · bcrypt(password,10) ·
--        Wallet.createRandom() → derive(0) · encryptKey(SALT,x) สองครั้ง ·
--        เก็บ AES string ลง DB · คืน 201 ไม่มี token
--
--   F13  ตาราง wallet เก็บ key ที่เข้ารหัสด้วย AES ไว้ในฐานข้อมูล
--
-- และข้อที่ล็อกไว้
--   L6   ตาราง wallet ไม่มีคอลัมน์ private key **ไม่มีวันมี**
--
-- "ไม่มีวันมี" เป็นคำที่แรงกว่า "ตอนนี้ไม่มี" · pack นี้จึงไม่หยุดที่
-- การไม่สร้างคอลัมน์นั้น แต่ใช้ event trigger ปฏิเสธ DDL ที่จะเพิ่มมันในอนาคต
--
-- อ้างอิง  F6 · F7 · F9 · F10 · F12 · F13 · L6 · L7 · SPEC-001
-- รันบน PostgreSQL 16 ได้ตรงๆ · ต้องมี pgcrypto
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------- enum
CREATE TYPE operation_kind AS ENUM (
  'MERCHANT_PROVISION', 'CUSTOMER_PROVISION', 'POINT_TYPE_CREATE',
  'POINT_TRANSFER', 'COUPON_TYPE_CREATE', 'COUPON_ISSUE', 'COUPON_REDEEM',
  'LISTING_CREATE', 'LISTING_DELETE', 'LISTING_BUY', 'THB_MINT'
);

CREATE TYPE operation_status AS ENUM (
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW'
);

CREATE TYPE step_status AS ENUM (
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED'
);

CREATE TYPE actor_type AS ENUM ('SYSTEM','MERCHANT_ADMIN','CUSTOMER','PLATFORM_ADMIN');

CREATE TYPE customer_status AS ENUM (
  'PENDING_WALLET',  -- ยืนยันเบอร์แล้ว รอ wallet ขึ้น chain
  'ACTIVE',
  'SUSPENDED',
  'CLOSED'
);

CREATE TYPE wallet_status AS ENUM ('REQUESTED','LIVE','FAILED');

CREATE TYPE challenge_status AS ENUM (
  'PENDING',   -- ส่ง OTP ไปแล้ว รอยืนยัน
  'VERIFIED',  -- ยืนยันถูกแล้ว · ใช้ได้ครั้งเดียว
  'CONSUMED',  -- ถูกใช้สมัครเรียบร้อย
  'EXPIRED',
  'LOCKED'     -- ใส่ผิดครบจำนวนครั้ง
);

CREATE TYPE attempt_result AS ENUM ('OK','WRONG_CODE','EXPIRED','LOCKED','ALREADY_USED');

-- ======================================================================
-- การทำให้เบอร์โทรเป็นรูปเดียว
--
-- F7 · ระบบเดิมเขียนทับเบอร์ด้วยค่าจาก body · ที่นี่เบอร์มาจาก challenge
-- เท่านั้น และ challenge ถูกสร้างจากเบอร์ที่ normalize แล้วครั้งเดียว
--
-- เก็บรูป E.164 เท่านั้น · ถ้าเก็บทั้ง 0812345678 และ +66812345678
-- จะได้สองบัญชีสำหรับคนเดียวกัน และ UNIQUE ก็กันไม่ได้
-- ======================================================================
CREATE OR REPLACE FUNCTION f_normalize_phone(p_raw text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d text; has_plus boolean;
BEGIN
  IF p_raw IS NULL THEN RETURN NULL; END IF;
  has_plus := left(btrim(p_raw), 1) = '+';
  d := regexp_replace(p_raw, '[^0-9]', '', 'g');
  IF d = '' THEN RETURN NULL; END IF;

  IF has_plus THEN
    RETURN '+' || d;
  END IF;
  -- เบอร์ไทย · สามรูปที่คนพิมพ์จริง
  IF left(d,2) = '66' AND length(d) = 11 THEN RETURN '+' || d; END IF;
  IF left(d,1) = '0'  AND length(d) = 10 THEN RETURN '+66' || substr(d,2); END IF;
  IF length(d) = 9 THEN RETURN '+66' || d; END IF;
  -- รูปที่ไม่รู้จัก · คืนค่าที่ CHECK จะปฏิเสธ ดีกว่าเดาแล้วผิด
  RETURN d;
END $$;

-- ======================================================================
-- ตัวตนของลูกค้า
--
-- ไม่มีคอลัมน์ password เลย · F12 ใช้ bcrypt(password,10)
-- ที่นี่ลูกค้าไม่มีรหัสผ่าน · OTP คือการยืนยันตัวตน
--
-- เหตุผล · รหัสผ่านที่ลูกค้าตั้งเองในแอปที่ใช้เบอร์โทรเป็นหลัก
-- สร้างช่องทางกู้คืนเพิ่มอีกช่อง ซึ่งเป็นช่องที่โจมตีง่ายที่สุด
-- และสุดท้ายการกู้คืนก็กลับมาที่ OTP อยู่ดี
-- merchant_admin ยังมีรหัสผ่าน (FEAT-03) เพราะคนละบริบท
-- ======================================================================
CREATE TABLE customer (
  id           text            PRIMARY KEY,
  phone_e164   text            NOT NULL
                 CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  display_name text,
  status       customer_status NOT NULL DEFAULT 'PENDING_WALLET',
  created_at   timestamptz     NOT NULL DEFAULT now(),
  -- เบอร์นี้ยืนยันแล้วเมื่อไร · ต้องมีค่าเสมอ เพราะสมัครไม่ได้ถ้าไม่ยืนยัน
  phone_verified_at timestamptz NOT NULL,
  CONSTRAINT ck_phone_normalized CHECK (phone_e164 = f_normalize_phone(phone_e164))
);
CREATE UNIQUE INDEX uq_customer_phone ON customer (phone_e164);

-- ======================================================================
-- wallet · ไม่มีคอลัมน์ private key และไม่มีวันมี (L6)
--
-- F13 · ระบบเดิมเก็บ key ที่เข้ารหัสด้วย AES ไว้ในฐานข้อมูล
-- F10 · และถอดรหัสเองเพื่อเซ็น
--
-- ที่นี่เก็บแค่ reference ไปที่ KMS · ระบบไม่เคยเห็น key
-- การเซ็นเกิดที่ KMS โดยส่ง digest ไปให้เซ็น ไม่ใช่ดึง key ออกมา
-- ======================================================================
CREATE TABLE wallet (
  address      bytea         PRIMARY KEY CHECK (octet_length(address) = 20),
  owner_kind   text          NOT NULL CHECK (owner_kind IN ('CUSTOMER','MERCHANT')),
  owner_id     text          NOT NULL,
  -- ตัวอย่าง 'kms://wallet/cus_abc/v1' · ห้ามเป็นค่าความลับเอง
  kms_key_ref  text          NOT NULL CHECK (kms_key_ref ~ '^kms://[A-Za-z0-9/_.:+=-]+$'
                                             AND length(kms_key_ref) <= 200),
  status       wallet_status NOT NULL DEFAULT 'REQUESTED',
  created_at   timestamptz   NOT NULL DEFAULT now(),
  live_at      timestamptz,
  CONSTRAINT ck_wallet_live CHECK ((status = 'LIVE') = (live_at IS NOT NULL))
);
CREATE UNIQUE INDEX uq_wallet_owner ON wallet (owner_kind, owner_id);

-- ======================================================================
-- "ไม่มีวันมี" ในรูปของกลไก ไม่ใช่ในรูปของคอมเมนต์
--
-- L6 เขียนว่า wallet ไม่มีคอลัมน์ private key **ไม่มีวันมี**
-- การไม่สร้างคอลัมน์นั้นวันนี้ ตอบได้แค่ครึ่งเดียว
-- อีกครึ่งคือกันคนที่จะเพิ่มมันในอีกสองปี ด้วยเจตนาดี
-- ตอนที่ไม่มีใครในทีมจำได้ว่าทำไมมันไม่มีตั้งแต่แรก
--
-- event trigger ทำงานที่ชั้น DDL · ปฏิเสธ ALTER TABLE ที่เพิ่มคอลัมน์
-- ซึ่งชื่อเข้าข่าย และปฏิเสธการสร้างตารางใหม่ที่มีคอลัมน์แบบนั้นด้วย
--
-- ข้อจำกัดที่ต้องรู้
--   event trigger ต้องสร้างโดย superuser · migration มักรันด้วยสิทธิ์นั้น
--   แต่ถ้า production รัน migration ด้วย user ธรรมดา ข้อนี้จะไม่ถูกสร้าง
--   จึงมีเทสต์ที่ตรวจว่า event trigger มีอยู่จริง (T14) ไม่ใช่แค่หวังว่ามี
--
--   และมันกันชื่อที่คิดไว้ ไม่ได้กันทุกวิธี · คนที่ตั้งใจเลี่ยงยังเลี่ยงได้
--   เป้าหมายคือทำให้การเผลอเป็นไปไม่ได้ ไม่ใช่กันคนที่ตั้งใจ
-- ======================================================================
CREATE OR REPLACE FUNCTION f_no_secret_columns() RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE r record; c record;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands()
           WHERE command_tag IN ('ALTER TABLE','CREATE TABLE')
  LOOP
    FOR c IN
      SELECT a.attname, cl.relname
        FROM pg_attribute a
        JOIN pg_class cl ON cl.oid = a.attrelid
       WHERE a.attrelid = r.objid
         AND a.attnum > 0 AND NOT a.attisdropped
         AND (
              a.attname ~* '(private|privkey|priv_key|secret|mnemonic|seed_phrase|seedphrase|keystore|encrypted_key|enc_key)'
           OR a.attname ~* '^(sk|xprv)$'
         )
    LOOP
      RAISE EXCEPTION 'ห้ามมีคอลัมน์ % ในตาราง % (L6)', c.attname, c.relname
        USING ERRCODE = 'insufficient_privilege',
              HINT = 'key อยู่ใน KMS เท่านั้น · เก็บได้แค่ kms_key_ref · F10 และ F13 เกิดจากการเก็บ key ไว้เอง';
    END LOOP;
  END LOOP;
END $$;

CREATE EVENT TRIGGER trg_no_secret_columns
  ON ddl_command_end
  WHEN TAG IN ('ALTER TABLE','CREATE TABLE')
  EXECUTE FUNCTION f_no_secret_columns();

-- ======================================================================
-- OTP challenge
--
-- F6 · ระบบเดิมคืนค่า OTP กลับมาใน response
--
-- ที่นี่ฐานข้อมูล **ไม่มีที่เก็บ OTP** · มีแต่ที่เก็บ hash ของมัน
-- จึงไม่มีอะไรให้คืนกลับไปแม้จะอยากคืน และ dump ฐานข้อมูลก็ไม่ได้ OTP
--
-- hash ใช้ HMAC กับ pepper ที่อยู่ใน KMS ไม่ใช่ sha256 เปล่า
--
--   OTP หกหลักมีความเป็นไปได้แค่ล้านแบบ
--   sha256 เปล่าของทั้งล้านแบบคำนวณเสร็จในเสี้ยววินาที
--   ใครได้ฐานข้อมูลไปก็ย้อนหา OTP ได้ทุกแถว
--
--   pepper ที่อยู่นอกฐานข้อมูลทำให้การย้อนต้องได้ทั้งสองอย่าง
--
-- ข้อควรระวัง · L7 / SPEC-001 [IK-23] ห้ามใช้ salt / secret / HMAC
-- แต่ข้อนั้นพูดถึง fingerprint ของ idempotency key เท่านั้น
-- เพราะ fingerprint ต้องคำนวณซ้ำได้โดยไม่ต้องรู้ความลับ
-- การเก็บ OTP เป็นงานตรงข้าม · ต้องให้คนที่ไม่รู้ความลับคำนวณไม่ได้
-- ======================================================================
CREATE TABLE otp_challenge (
  id            text             PRIMARY KEY,
  phone_e164    text             NOT NULL
                  CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  -- HMAC-SHA256 ของ (challenge_id || ':' || code) ด้วย pepper จาก KMS
  code_hash     bytea            NOT NULL CHECK (octet_length(code_hash) = 32),
  pepper_ref    text             NOT NULL CHECK (pepper_ref ~ '^kms://'),
  status        challenge_status NOT NULL DEFAULT 'PENDING',
  attempts      integer          NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts  integer          NOT NULL DEFAULT 5
                  CHECK (max_attempts BETWEEN 1 AND 10),
  created_at    timestamptz      NOT NULL DEFAULT now(),
  expires_at    timestamptz      NOT NULL,
  verified_at   timestamptz,
  consumed_at   timestamptz,
  CONSTRAINT ck_ch_verified  CHECK ((verified_at IS NOT NULL)
                                    = (status IN ('VERIFIED','CONSUMED'))),
  CONSTRAINT ck_ch_consumed  CHECK ((consumed_at IS NOT NULL) = (status = 'CONSUMED')),
  CONSTRAINT ck_ch_attempts  CHECK (attempts <= max_attempts),
  CONSTRAINT ck_ch_window    CHECK (expires_at > created_at),
  CONSTRAINT ck_ch_normalized CHECK (phone_e164 = f_normalize_phone(phone_e164))
);
-- หนึ่งเบอร์มี challenge ที่ยังใช้ได้ทีละอันเดียว
-- ขอใหม่ = อันเก่าหมดอายุทันที · ไม่ใช่มีสองอันใช้ได้พร้อมกัน
CREATE UNIQUE INDEX uq_challenge_live ON otp_challenge (phone_e164)
  WHERE status = 'PENDING';
CREATE INDEX ix_challenge_expiring ON otp_challenge (expires_at)
  WHERE status = 'PENDING';

-- ======================================================================
-- เส้นทางสถานะของ challenge
-- ======================================================================
CREATE OR REPLACE FUNCTION f_challenge_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- ค่าที่ตั้งตอนสร้างห้ามเปลี่ยน · เปลี่ยนเบอร์หรือ hash ได้คือ F7 กลับมา
  IF NEW.phone_e164 <> OLD.phone_e164
     OR NEW.code_hash <> OLD.code_hash
     OR NEW.pepper_ref <> OLD.pepper_ref
     OR NEW.expires_at <> OLD.expires_at THEN
    RAISE EXCEPTION 'challenge % แก้เบอร์ รหัส หรือเวลาหมดอายุไม่ได้', OLD.id
      USING ERRCODE = 'check_violation',
            HINT = 'F7 · ระบบเดิมเขียนทับเบอร์ด้วยค่าจาก body';
  END IF;

  IF OLD.status = NEW.status THEN RETURN NEW; END IF;

  IF NOT (
       (OLD.status = 'PENDING'  AND NEW.status IN ('VERIFIED','EXPIRED','LOCKED'))
    OR (OLD.status = 'VERIFIED' AND NEW.status IN ('CONSUMED','EXPIRED'))
  ) THEN
    RAISE EXCEPTION 'challenge % เปลี่ยนสถานะจาก % ไป % ไม่ได้',
      OLD.id, OLD.status, NEW.status USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'VERIFIED' AND NEW.verified_at IS NULL THEN
    NEW.verified_at := now();
  END IF;
  IF NEW.status = 'CONSUMED' AND NEW.consumed_at IS NULL THEN
    NEW.consumed_at := now();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_challenge_transition
  BEFORE UPDATE ON otp_challenge
  FOR EACH ROW EXECUTE FUNCTION f_challenge_transition();

-- ======================================================================
-- ทุกครั้งที่มีคนลองใส่รหัส · Group E (ตาม FEAT-13)
--
-- เก็บเพื่อสองเรื่อง
--   เห็นการเดารหัสเป็นชุด ซึ่งนับเฉพาะใน challenge เดียวไม่เห็น
--   ตอบลูกค้าได้ว่าเกิดอะไรขึ้นกับบัญชีเขา
--
-- ไม่เก็บรหัสที่ใส่ผิดเข้ามา · เก็บแต่ว่าผิด
-- เพราะคนมักพิมพ์รหัสของที่อื่นผิดมาลงที่นี่
-- ======================================================================
CREATE TABLE otp_attempt (
  id           text           PRIMARY KEY,
  challenge_id text           NOT NULL REFERENCES otp_challenge(id) ON DELETE CASCADE,
  attempt_no   integer        NOT NULL CHECK (attempt_no >= 1),
  result       attempt_result NOT NULL,
  ip_hash      bytea          CHECK (ip_hash IS NULL OR octet_length(ip_hash) = 32),
  created_at   timestamptz    NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_attempt_no ON otp_attempt (challenge_id, attempt_no);
CREATE INDEX ix_attempt_recent ON otp_attempt (created_at);

-- ======================================================================
-- attempts นับ "การเดา" ไม่ใช่ "การเรียก"
--
-- ความแตกต่างนี้สำคัญ และรอบแรกผมเขียนผิด
--
--   เรียกตอน challenge ถูกล็อกไปแล้ว ไม่ใช่การเดา · รหัสไม่ถูกเอามาเทียบเลย
--   ถ้านับเป็นการเดา attempts จะเกิน max_attempts แล้ว CHECK พัง
--   และ T21 จับได้
--
-- otp_attempt บันทึก **ทุกการเรียก** เพราะนั่นคือสิ่งที่ต้องเห็น
-- คนที่ยิงรัวที่ challenge ที่ล็อกแล้วเป็นข้อมูลด้านความปลอดภัย
-- ทิ้งไปเงียบๆ แปลว่ามีคนลองแล้วไม่มีใครรู้
--
-- จึงเทียบ attempts กับจำนวนแถวที่ผลเป็นการเดาจริง ไม่ใช่ทุกแถว
-- ======================================================================
CREATE OR REPLACE FUNCTION f_attempt_count_matches() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_n integer; v_claimed integer;
BEGIN
  SELECT attempts INTO v_claimed FROM otp_challenge WHERE id = NEW.challenge_id;
  SELECT count(*) INTO v_n FROM otp_attempt
   WHERE challenge_id = NEW.challenge_id AND result IN ('OK','WRONG_CODE');
  IF v_claimed <> v_n THEN
    RAISE EXCEPTION 'challenge % นับว่าเดาไป % ครั้ง แต่มีแถวที่เป็นการเดา % แถว',
      NEW.challenge_id, v_claimed, v_n
      USING ERRCODE = 'check_violation',
            HINT = 'attempts นับการเดา ไม่ใช่การเรียก · LOCKED และ EXPIRED ไม่นับ';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_attempt_count_matches
  AFTER INSERT ON otp_attempt
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION f_attempt_count_matches();

-- ======================================================================
-- จำกัดการขอ OTP ต่อเบอร์
--
-- ไม่มีข้อนี้ ใครก็ส่ง SMS ไปรบกวนเบอร์คนอื่นได้ฟรีเท่าที่อยาก
-- และค่า SMS เป็นของเรา
-- ======================================================================
CREATE TABLE phone_throttle (
  phone_e164    text        PRIMARY KEY
                  CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  window_start  timestamptz NOT NULL DEFAULT now(),
  sent_count    integer     NOT NULL DEFAULT 0 CHECK (sent_count >= 0),
  last_sent_at  timestamptz,
  locked_until  timestamptz
);

-- ขอ OTP ถี่เกินไป หรือยังอยู่ในช่วงล็อก → ปฏิเสธ
CREATE OR REPLACE FUNCTION f_throttle_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v record; v_cool interval := interval '60 seconds'; v_max integer := 5;
BEGIN
  SELECT * INTO v FROM phone_throttle WHERE phone_e164 = NEW.phone_e164;
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF v.locked_until IS NOT NULL AND v.locked_until > now() THEN
    RAISE EXCEPTION 'เบอร์ % ถูกล็อกถึง %', NEW.phone_e164, v.locked_until
      USING ERRCODE = 'check_violation';
  END IF;
  IF v.last_sent_at IS NOT NULL AND v.last_sent_at + v_cool > now() THEN
    RAISE EXCEPTION 'ขอ OTP ถี่เกินไป · รออีก % วินาที',
      ceil(extract(epoch FROM (v.last_sent_at + v_cool - now())))
      USING ERRCODE = 'check_violation';
  END IF;
  IF v.window_start + interval '1 hour' > now() AND v.sent_count >= v_max THEN
    RAISE EXCEPTION 'เบอร์ % ขอ OTP ครบ % ครั้งในหนึ่งชั่วโมงแล้ว', NEW.phone_e164, v_max
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_throttle_check
  BEFORE INSERT ON otp_challenge
  FOR EACH ROW EXECUTE FUNCTION f_throttle_check();

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
CREATE UNIQUE INDEX uq_provision_inflight
  ON operation (subject_id)
  WHERE kind = 'CUSTOMER_PROVISION' AND status NOT IN ('FINALIZED','CHAIN_REVERTED');

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

CREATE TABLE signer (
  address    bytea PRIMARY KEY CHECK (octet_length(address) = 20),
  key_ref    text    NOT NULL CHECK (key_ref ~ '^kms://'),
  next_nonce bigint  NOT NULL DEFAULT 0 CHECK (next_nonce >= 0),
  enabled    boolean NOT NULL DEFAULT true
);

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
  CONSTRAINT ck_rawtx_before_broadcast
    CHECK (status = 'PENDING' OR raw_tx IS NOT NULL)
);
CREATE UNIQUE INDEX uq_step_order  ON operation_step (operation_id, step_index);
CREATE UNIQUE INDEX uq_step_txhash ON operation_step (tx_hash) WHERE tx_hash IS NOT NULL;

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
  metadata     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ======================================================================
-- session · F12 คืน 201 ไม่มี token
--
-- ที่นี่ยืนยัน OTP สำเร็จแล้วได้ session ทันที
-- ลูกค้าไม่ต้องทำขั้นตอนที่สองเพื่อเข้าสู่ระบบ
--
-- เก็บแต่ hash ของ token · ตารางนี้ไม่มีที่เก็บ token เหมือนที่
-- otp_challenge ไม่มีที่เก็บ OTP
-- ======================================================================
CREATE TABLE customer_session (
  id            text        PRIMARY KEY,
  customer_id   text        NOT NULL REFERENCES customer(id),
  token_hash    bytea       NOT NULL CHECK (octet_length(token_hash) = 32),
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  revoked_at    timestamptz,
  CONSTRAINT ck_session_window CHECK (expires_at > created_at)
);
CREATE UNIQUE INDEX uq_session_token ON customer_session (token_hash);
CREATE INDEX ix_session_live ON customer_session (customer_id)
  WHERE revoked_at IS NULL;

-- ======================================================================
-- กฎที่ปิด F7 โดยตรง
--
-- เบอร์ของลูกค้าที่สร้างใหม่ ต้องมาจาก challenge ที่ VERIFIED แล้ว
-- และต้องเป็นเบอร์เดียวกับใน challenge นั้นเป๊ะ
--
-- ระบบเดิมเอาเบอร์จาก body ของ request · ที่นี่ body ไม่มีเบอร์ให้ส่ง
-- และถ้ามีใครเติมเข้ามาในอนาคต trigger นี้จะปฏิเสธ
-- ======================================================================
CREATE OR REPLACE FUNCTION f_customer_phone_from_challenge() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_ch text; v_phone text; v_st challenge_status;
BEGIN
  -- challenge ที่ใช้สมัครถูกส่งมาทาง parameter ของ session
  v_ch := current_setting('app.verified_challenge', true);
  IF v_ch IS NULL OR v_ch = '' THEN
    RAISE EXCEPTION 'สร้างลูกค้าโดยไม่อ้าง challenge ที่ยืนยันแล้วไม่ได้'
      USING ERRCODE = 'check_violation',
            HINT = 'F7 · เบอร์ต้องมาจาก challenge ไม่ใช่จาก request';
  END IF;

  SELECT phone_e164, status INTO v_phone, v_st
    FROM otp_challenge WHERE id = v_ch;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบ challenge %', v_ch USING ERRCODE = 'check_violation';
  END IF;
  IF v_st <> 'VERIFIED' THEN
    RAISE EXCEPTION 'challenge % อยู่สถานะ % · ใช้สมัครไม่ได้', v_ch, v_st
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.phone_e164 <> v_phone THEN
    RAISE EXCEPTION 'เบอร์ที่สมัคร % ไม่ตรงกับเบอร์ที่ยืนยันไว้ %',
      NEW.phone_e164, v_phone
      USING ERRCODE = 'check_violation',
            HINT = 'F7 · ระบบเดิมเขียนทับเบอร์ด้วยค่าจาก body';
  END IF;
  IF NEW.phone_verified_at IS DISTINCT FROM NULL
     AND NEW.phone_verified_at < (SELECT verified_at FROM otp_challenge WHERE id = v_ch)
  THEN
    RAISE EXCEPTION 'phone_verified_at เก่ากว่าเวลาที่ยืนยันจริง'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_customer_phone_from_challenge
  BEFORE INSERT ON customer
  FOR EACH ROW EXECUTE FUNCTION f_customer_phone_from_challenge();

-- เบอร์ของลูกค้าแก้ไม่ได้หลังสร้าง · เปลี่ยนเบอร์ต้องยืนยันเบอร์ใหม่
CREATE OR REPLACE FUNCTION f_customer_phone_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.phone_e164 <> OLD.phone_e164 THEN
    RAISE EXCEPTION 'เปลี่ยนเบอร์ของลูกค้า % ตรงๆ ไม่ได้ · ต้องยืนยันเบอร์ใหม่', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.phone_verified_at <> OLD.phone_verified_at THEN
    RAISE EXCEPTION 'แก้เวลาที่ยืนยันเบอร์ไม่ได้' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_customer_phone_immutable
  BEFORE UPDATE ON customer
  FOR EACH ROW EXECUTE FUNCTION f_customer_phone_immutable();

-- ======================================================================
-- ยืนยัน OTP · ฟังก์ชันเดียวที่ทำได้
--
-- อยู่ในฐานข้อมูลเพราะการนับครั้งที่ลอง การล็อก และการเทียบ hash
-- ต้องเกิดใน transaction เดียว · แยกเป็นหลายคำสั่งจะมีช่องให้ยิงขนาน
-- แล้วได้ลองเกินจำนวนครั้งที่กำหนด (เรื่องเดียวกับ F1)
--
-- ไม่รับเบอร์โทรเป็น parameter เลย · รับแค่ challenge_id กับ code
-- F7 ปิดตั้งแต่หน้าประตู ไม่ใช่ปิดด้วยการตรวจทีหลัง
-- ======================================================================
CREATE OR REPLACE FUNCTION f_verify_otp(
  p_challenge_id text, p_code text, p_pepper text, p_ip_hash bytea DEFAULT NULL
) RETURNS attempt_result
LANGUAGE plpgsql AS $$
DECLARE c otp_challenge; v_n integer; v_hash bytea; v_res attempt_result;
BEGIN
  -- ล็อกแถวไว้ · สองคำขอพร้อมกันจึงเข้าคิว ไม่ใช่นับครั้งทับกัน
  SELECT * INTO c FROM otp_challenge WHERE id = p_challenge_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบ challenge %', p_challenge_id USING ERRCODE = 'check_violation';
  END IF;

  IF c.status IN ('CONSUMED','VERIFIED') THEN v_res := 'ALREADY_USED';
  ELSIF c.status = 'LOCKED'              THEN v_res := 'LOCKED';
  ELSIF c.status = 'EXPIRED'
     OR c.expires_at <= now()            THEN v_res := 'EXPIRED';
  ELSE
    v_hash := hmac(p_challenge_id || ':' || p_code, p_pepper, 'sha256');
    --
    -- ข้อจำกัดที่ต้องพูดให้ชัด · การเทียบ bytea ใน Postgres ใช้ memcmp
    -- ซึ่ง **ไม่ใช่ constant time** · เทียบ hash สองค่าที่ต่างกันตั้งแต่ byte แรก
    -- เร็วกว่าเทียบค่าที่ต่างกันที่ byte สุดท้าย
    --
    -- เหตุผลที่ยังยอมรับได้ที่นี่
    --   สิ่งที่เทียบคือ hash ไม่ใช่ OTP · คนที่วัดเวลาได้ก็ต้องเดา hash
    --   ไม่ใช่เดา OTP และ hash มี 2^256 ความเป็นไปได้
    --   และการจำกัดครั้งที่ลอง (max_attempts) ตัดการวัดซ้ำที่จำเป็น
    --   สำหรับการโจมตีแบบนี้ไปแล้ว
    --
    -- ถ้าวันหนึ่งต้องการ constant time จริง ต้องย้ายการเทียบไปที่โค้ด
    -- แล้วใช้ timingSafeEqual ซึ่งแลกมาด้วยการที่ hash ต้องออกจากฐานข้อมูล
    IF v_hash = c.code_hash THEN v_res := 'OK'; ELSE v_res := 'WRONG_CODE'; END IF;
  END IF;

  -- บันทึกทุกการเรียก · attempt_no เดินตามจำนวนแถว ไม่ใช่ตาม attempts
  SELECT count(*) + 1 INTO v_n FROM otp_attempt WHERE challenge_id = p_challenge_id;
  INSERT INTO otp_attempt (id, challenge_id, attempt_no, result, ip_hash)
  VALUES ('oa_' || p_challenge_id || '_' || v_n, p_challenge_id, v_n, v_res, p_ip_hash);

  -- นับเฉพาะที่เอารหัสมาเทียบจริง · ล็อกแล้วหรือหมดอายุไม่ใช่การเดา
  IF v_res IN ('OK','WRONG_CODE') THEN
    UPDATE otp_challenge SET attempts = c.attempts + 1 WHERE id = p_challenge_id;
  END IF;

  IF v_res = 'OK' THEN
    UPDATE otp_challenge SET status = 'VERIFIED' WHERE id = p_challenge_id;
  ELSIF v_res = 'WRONG_CODE' AND c.attempts + 1 >= c.max_attempts THEN
    UPDATE otp_challenge SET status = 'LOCKED' WHERE id = p_challenge_id;
    UPDATE phone_throttle SET locked_until = now() + interval '30 minutes'
     WHERE phone_e164 = c.phone_e164;
  ELSIF v_res = 'EXPIRED' AND c.status = 'PENDING' THEN
    UPDATE otp_challenge SET status = 'EXPIRED' WHERE id = p_challenge_id;
  END IF;

  RETURN v_res;
END $$;

COMMIT;
