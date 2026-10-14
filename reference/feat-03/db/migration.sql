-- =====================================================================
-- FEAT-03 · Auth · login, token, refresh
-- access token อายุสั้นไม่เก็บลงฐานข้อมูล · refresh token เก็บเป็น hash
-- และหมุนทุกครั้งที่ใช้ · ใช้ซ้ำเมื่อไหร่ ทั้งสายถูกเพิกถอน
-- อ้างอิง  RFD 16 §3.4 · RFD 8 D7 · RFD 3 D1
-- รันบน PostgreSQL 16 ได้ตรงๆ
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------- enum
CREATE TYPE subject_kind AS ENUM ('MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

CREATE TYPE revoke_reason AS ENUM (
  'LOGOUT',            -- ผู้ใช้กดออกจากระบบเอง
  'ROTATED',           -- หมุนแล้ว ใบเก่าหมดหน้าที่
  'REUSE_DETECTED',    -- มีคนเอาใบที่ใช้ไปแล้วมาใช้อีก
  'PASSWORD_CHANGED',
  'ADMIN_REVOKED',
  'EXPIRED'
);

CREATE TYPE merchant_status AS ENUM ('PENDING', 'ACTIVE', 'SUSPENDED', 'CLOSED');

-- ---------------------------------------------------- ตัวตน (จาก FEAT-01)
CREATE TABLE merchant (
  id          text PRIMARY KEY,
  name        text            NOT NULL,
  status      merchant_status NOT NULL DEFAULT 'PENDING',
  created_at  timestamptz     NOT NULL DEFAULT now()
);

CREATE TABLE merchant_admin (
  id               text PRIMARY KEY,
  merchant_id      text        NOT NULL REFERENCES merchant(id),
  email            text        NOT NULL,
  email_normalized text        NOT NULL CHECK (email_normalized = lower(btrim(email_normalized))),
  -- RFD 8 D7 · argon2id เท่านั้น · bcrypt และ plaintext เข้าไม่ได้
  password_hash    text        NOT NULL CHECK (password_hash LIKE '$argon2id$%'),
  display_name     text        NOT NULL,
  disabled_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_login_at    timestamptz
);
CREATE UNIQUE INDEX uq_admin_email ON merchant_admin (email_normalized);

CREATE TABLE customer (
  id          text PRIMARY KEY,
  tel_hash    bytea       NOT NULL,
  disabled_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_customer_tel ON customer (tel_hash);

-- ------------------------------------------------------- session / token
-- RFD 16 §3.4 · ตัดสินว่าใช้ access token แบบ JWT อายุสั้น
-- คู่กับ refresh token ที่เป็นแถวในฐานข้อมูล
--
-- ทำไมไม่เก็บ access token ลงตาราง · อายุ 15 นาที การ query ทุก request
-- เพื่อเช็คว่าถูกเพิกถอนหรือยัง ทำให้ JWT ไม่มีประโยชน์ที่เหลืออยู่เลย
-- การเพิกถอนจึงเกิดที่ refresh แทน · ผลคือ worst case ผู้ใช้ที่ถูกแบน
-- ยังใช้ access token ใบเดิมได้อีกไม่เกิน 15 นาที ซึ่งยอมรับได้
--
-- ทำไมไม่เก็บ refresh token เป็น plaintext · ถ้าฐานข้อมูลรั่ว
-- คนอ่านได้จะสวมรอยเป็นผู้ใช้ทุกคนทันที · เก็บ sha256 แล้วเทียบตอนใช้
CREATE TABLE auth_session (
  id                 text PRIMARY KEY,
  subject_kind       subject_kind NOT NULL,
  merchant_admin_id  text REFERENCES merchant_admin(id),
  customer_id        text REFERENCES customer(id),
  -- หนึ่งสายของการหมุน token · ทุกใบในสายเดียวกันถูกเพิกถอนพร้อมกันได้
  family_id          text        NOT NULL,
  -- sha256 ของ refresh token · plaintext ไม่เคยอยู่ในตารางนี้
  refresh_token_hash bytea       NOT NULL CHECK (octet_length(refresh_token_hash) = 32),
  parent_id          text REFERENCES auth_session(id),
  user_agent_hash    bytea,
  ip_hash            bytea,
  created_at         timestamptz NOT NULL DEFAULT now(),
  expires_at         timestamptz NOT NULL,
  used_at            timestamptz,
  revoked_at         timestamptz,
  revoked_reason     revoke_reason,

  -- เจ้าของต้องเป็นคนใดคนหนึ่ง ไม่ใช่ทั้งคู่ ไม่ใช่ไม่มีเลย
  CONSTRAINT ck_one_subject CHECK (num_nonnulls(merchant_admin_id, customer_id) = 1),
  CONSTRAINT ck_subject_matches CHECK (
    (subject_kind = 'MERCHANT_ADMIN' AND merchant_admin_id IS NOT NULL) OR
    (subject_kind = 'CUSTOMER'       AND customer_id       IS NOT NULL)
  ),
  CONSTRAINT ck_expiry_after_create CHECK (expires_at > created_at),
  -- เพิกถอนแล้วต้องบอกเหตุผลเสมอ · ไม่มีการเพิกถอนแบบไม่มีที่มา
  CONSTRAINT ck_revoke_has_reason CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
);

CREATE UNIQUE INDEX uq_session_token ON auth_session (refresh_token_hash);

-- หัวใจของการกันการใช้ซ้ำ
-- token หนึ่งใบหมุนได้ครั้งเดียว · ถ้ามีคนเอาใบเดิมมาหมุนอีก
-- การ INSERT ลูกใบที่สองจะชนที่ index นี้ ไม่ต้องพึ่งโค้ดเช็ค
CREATE UNIQUE INDEX uq_session_parent
  ON auth_session (parent_id) WHERE parent_id IS NOT NULL;

CREATE INDEX ix_session_family ON auth_session (family_id);
CREATE INDEX ix_session_subject ON auth_session (subject_kind, merchant_admin_id, customer_id);
-- index ครอบเฉพาะใบที่ยังใช้ได้ · ขนาดเท่าจำนวน session ที่ active จริง
CREATE INDEX ix_session_live ON auth_session (expires_at)
  WHERE used_at IS NULL AND revoked_at IS NULL;

-- --------------------------------------------------------- login attempt
-- นับเฉพาะครั้งที่ล้มเหลว เพื่อล็อกบัญชีชั่วคราว
-- เก็บ identifier เป็น hash ไม่เก็บอีเมลตรงๆ
CREATE TABLE login_attempt (
  id              text PRIMARY KEY,
  identifier_hash bytea       NOT NULL CHECK (octet_length(identifier_hash) = 32),
  ip_hash         bytea       NOT NULL CHECK (octet_length(ip_hash) = 32),
  succeeded       boolean     NOT NULL,
  failure_code    text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- สำเร็จแล้วต้องไม่มีรหัสความล้มเหลว
  CONSTRAINT ck_failure_code CHECK (succeeded = (failure_code IS NULL))
);
CREATE INDEX ix_attempt_identifier ON login_attempt (identifier_hash, created_at)
  WHERE NOT succeeded;
CREATE INDEX ix_attempt_ip ON login_attempt (ip_hash, created_at)
  WHERE NOT succeeded;

-- ล็อกบัญชีชั่วคราวเมื่อพลาดเกินเกณฑ์
CREATE TABLE login_lockout (
  identifier_hash bytea PRIMARY KEY CHECK (octet_length(identifier_hash) = 32),
  locked_until    timestamptz NOT NULL,
  attempt_count   integer     NOT NULL CHECK (attempt_count > 0),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------- audit
CREATE TABLE auth_event (
  id           text PRIMARY KEY,
  subject_kind subject_kind,
  subject_id   text,
  kind         text        NOT NULL,   -- LOGIN_OK LOGIN_FAIL REFRESH LOGOUT REUSE_DETECTED
  session_id   text REFERENCES auth_session(id),
  ip_hash      bytea,
  metadata     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_auth_event_subject ON auth_event (subject_kind, subject_id, created_at);
CREATE INDEX ix_auth_event_kind ON auth_event (kind, created_at);

COMMIT;
