-- =====================================================================
-- FEAT-13 · Operation Status + Webhook · migration
-- บอกโลกข้างนอกว่างานที่รับไว้เป็นอย่างไรแล้ว
--
-- ทุก pack ก่อนหน้านี้ "เขียน" operation operation_step operation_event
-- feature นี้คือตัวที่ "อ่าน" มันแล้วเล่าให้คนข้างนอกฟัง สองทาง
--   ดึง  GET /v1/operations/{id}
--   ส่ง  webhook ไปที่ endpoint ที่ร้านลงทะเบียนไว้
--
-- ======================================================================
-- ข้อที่ feature นี้ต้องตัดสิน · RFD 6 ค้างไว้
--
-- RFD 6 §3.2 ตั้งกฎของ Group D ว่า "ลบทิ้งทั้งตาราง แล้ว replay
-- chain_event ใหม่ ต้องได้ค่าเดิมเป๊ะ" และตั้งข้อสังเกตว่า
-- webhook_delivery ทำแบบนั้นไม่ได้ จึงควรแยกเป็น Group E (ยังไม่ตัดสิน)
--
-- pack นี้ตัดสินว่า **แยก** และนี่คือเหตุผล
--
--   webhook_delivery เก็บสิ่งที่เกิดขึ้นข้างนอกระบบ
--   ลบแล้ว replay ไม่ได้แปลว่าได้ข้อมูลเดิมคืน แต่แปลว่า
--   **ยิง webhook ไปหาร้านใหม่ทั้งหมด** ซึ่งเป็นผลข้างเคียงกับคนอื่น
--
--   และค่าที่อยู่ในตารางนี้ไม่มีอะไรสืบกลับไปหา chain_event ได้เลย
--   response_status ที่ร้านตอบกลับ · เวลาที่ยิงจริง · จำนวนครั้งที่ลอง
--   chain ไม่รู้เรื่องพวกนี้ และจะไม่มีวันรู้
--
-- Group D = projection · สืบจาก chain ได้ · ลบแล้วสร้างใหม่ได้
-- Group E = บันทึกการทำงาน · เป็นหลักฐานว่าเราทำอะไรไปแล้ว · ลบแล้วหายเลย
--
-- ตารางใน Group E ที่ pack นี้สร้าง
--   webhook_endpoint          ของที่ร้านตั้งไว้
--   webhook_delivery          งานส่งหนึ่งชิ้น
--   webhook_delivery_attempt  การยิงหนึ่งครั้งและคำตอบที่ได้
-- ======================================================================
--
-- อ้างอิง  RFD 2 · RFD 5 · RFD 6 §3.2 · RFD 13 · L6 · L7
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
CREATE TYPE actor_type AS ENUM ('SYSTEM', 'MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN');

CREATE TYPE delivery_status AS ENUM (
  'PENDING',    -- รอยิง
  'IN_FLIGHT',  -- กำลังยิง · มี worker ถือไว้
  'SENT',       -- ร้านตอบ 2xx
  'DEAD'        -- ลองครบจำนวนแล้วยังไม่ผ่าน
);

CREATE TYPE endpoint_status AS ENUM ('ACTIVE', 'PAUSED', 'DISABLED');

-- ------------------------------------------------------------ ตัวตน
CREATE TABLE merchant (
  id         text PRIMARY KEY,
  name       text            NOT NULL,
  status     merchant_status NOT NULL DEFAULT 'PENDING',
  created_at timestamptz     NOT NULL DEFAULT now()
);

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
CREATE INDEX ix_operation_actor ON operation (actor_scope, created_at DESC);

ALTER TABLE idempotency_key
  ADD CONSTRAINT fk_idem_operation FOREIGN KEY (operation_id) REFERENCES operation(id);

CREATE TABLE operation_step (
  id             text PRIMARY KEY,
  operation_id   text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  step_index     integer     NOT NULL CHECK (step_index >= 1),
  name           text        NOT NULL,
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
CREATE UNIQUE INDEX uq_step_order  ON operation_step (operation_id, step_index);
CREATE UNIQUE INDEX uq_step_txhash ON operation_step (tx_hash) WHERE tx_hash IS NOT NULL;

-- ======================================================================
-- บันทึกทุก transition · และนี่คือตารางที่ client ควรอ่าน ไม่ใช่ operation.status
--
-- seq เป็นเลขลำดับต่อหนึ่ง operation · เพิ่มขึ้นเสมอ
-- client เทียบ seq ไม่ใช่เทียบ status เพราะ **status ไม่ monotonic**
--
-- reorg ทำให้ CONFIRMED กลายเป็น ORPHANED ได้ ซึ่งถอยหลังในสายตาคนทั่วไป
-- แต่ถูกต้องตามความจริงของ chain · ถ้า client สมมติว่า status เดินหน้าเสมอ
-- มันจะทิ้ง event ที่สำคัญที่สุดไป
-- ======================================================================
CREATE TABLE operation_event (
  id           text PRIMARY KEY,
  operation_id text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  seq          integer     NOT NULL CHECK (seq >= 1),
  from_status  operation_status,
  to_status    operation_status NOT NULL,
  actor        actor_type  NOT NULL DEFAULT 'SYSTEM',
  tx_hash      bytea,
  metadata     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  -- แถวแรกเท่านั้นที่ from_status เป็น NULL ได้
  CONSTRAINT ck_first_event CHECK ((seq = 1) = (from_status IS NULL))
);
CREATE UNIQUE INDEX uq_opevent_seq ON operation_event (operation_id, seq);
CREATE INDEX ix_opevent_by_op ON operation_event (operation_id, seq);

-- ======================================================================
-- เส้นทางสถานะของ operation
--
-- pack ก่อนๆ บังคับเส้นทางของ listing และ deposit แต่ไม่เคยบังคับของ
-- operation เอง · ที่นี่ต้องบังคับ เพราะ feature นี้คือตัวที่เอา status
-- ไปบอกคนข้างนอก · status ที่เชื่อถือไม่ได้ทำให้ทั้ง feature ไร้ความหมาย
--
-- ข้อสังเกตที่สำคัญ · ORPHANED → SUBMITTED และ CONFIRMED → ORPHANED
-- เป็นเส้นทางที่ถูกต้อง แต่ไม่ใช่การ "เดินหน้า"
-- reorg มีจริง จึงไม่มีการรับประกันว่า status จะเดินหน้าทางเดียว
-- ======================================================================
CREATE OR REPLACE FUNCTION f_operation_status_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;

  IF NOT (
       (OLD.status = 'PENDING'        AND NEW.status IN ('SUBMITTED','MANUAL_REVIEW'))
    OR (OLD.status = 'SUBMITTED'      AND NEW.status IN ('CONFIRMED','CHAIN_REVERTED',
                                                         'ORPHANED','MANUAL_REVIEW'))
    OR (OLD.status = 'CONFIRMED'      AND NEW.status IN ('FINALIZED','ORPHANED',
                                                         'MANUAL_REVIEW'))
    -- reorg · tx หลุดจาก chain แล้วถูกยิงใหม่
    OR (OLD.status = 'ORPHANED'       AND NEW.status IN ('SUBMITTED','MANUAL_REVIEW'))
    OR (OLD.status = 'MANUAL_REVIEW'  AND NEW.status IN ('SUBMITTED','CHAIN_REVERTED',
                                                         'FINALIZED'))
  ) THEN
    RAISE EXCEPTION 'operation % เปลี่ยนสถานะจาก % ไป % ไม่ได้',
      OLD.id, OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'FINALIZED' AND NEW.finalized_at IS NULL THEN
    NEW.finalized_at := now();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_operation_status_transition
  BEFORE UPDATE ON operation
  FOR EACH ROW EXECUTE FUNCTION f_operation_status_transition();

-- ======================================================================
-- from_status ของ event ต้องตรงกับสถานะจริงก่อนหน้า
-- เขียนเลขอะไรก็ได้ลงไปแล้วประวัติจะโกหก
-- ======================================================================
CREATE OR REPLACE FUNCTION f_opevent_chain_intact() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_prev_to operation_status; v_prev_seq integer;
BEGIN
  SELECT to_status, seq INTO v_prev_to, v_prev_seq
    FROM operation_event
   WHERE operation_id = NEW.operation_id AND seq < NEW.seq
   ORDER BY seq DESC LIMIT 1;

  IF NEW.seq = 1 THEN
    IF v_prev_seq IS NOT NULL THEN
      RAISE EXCEPTION 'operation % มี event seq 1 อยู่แล้ว', NEW.operation_id
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  IF v_prev_seq IS NULL THEN
    RAISE EXCEPTION 'event seq % ของ operation % ไม่มีแถวก่อนหน้า · ประวัติขาดช่วง',
      NEW.seq, NEW.operation_id USING ERRCODE = 'check_violation';
  END IF;
  IF v_prev_seq <> NEW.seq - 1 THEN
    RAISE EXCEPTION 'event ของ operation % กระโดดจาก seq % ไป % · ต้องเรียงติดกัน',
      NEW.operation_id, v_prev_seq, NEW.seq USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.from_status <> v_prev_to THEN
    RAISE EXCEPTION 'event seq % บอกว่ามาจาก % แต่แถวก่อนหน้าจบที่ %',
      NEW.seq, NEW.from_status, v_prev_to USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_opevent_chain_intact
  BEFORE INSERT ON operation_event
  FOR EACH ROW EXECUTE FUNCTION f_opevent_chain_intact();

-- ======================================================================
-- ทุกการเปลี่ยนสถานะต้องมีแถว operation_event รองรับ · ตรวจตอน COMMIT
--
-- ต้อง deferred เพราะลำดับการเขียนไม่แน่ · บางที่อัปเดต operation ก่อน
-- บางที่เขียน event ก่อน · ทั้งสองแบบถูก ขอแค่ตอน COMMIT มันครบ
--
-- ถ้าไม่มีกฎนี้ จะมี operation ที่สถานะเปลี่ยนโดยไม่มีประวัติ
-- และ API ที่เล่าประวัติให้ลูกค้าฟังก็จะเล่าไม่ครบ โดยไม่มีใครรู้
-- ======================================================================
CREATE OR REPLACE FUNCTION f_status_has_event() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status operation_status; v_last operation_status;
BEGIN
  SELECT status INTO v_status FROM operation WHERE id = NEW.id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT to_status INTO v_last FROM operation_event
   WHERE operation_id = NEW.id ORDER BY seq DESC LIMIT 1;

  IF v_last IS DISTINCT FROM v_status THEN
    RAISE EXCEPTION 'operation % อยู่สถานะ % แต่ event แถวสุดท้ายจบที่ %',
      NEW.id, v_status, coalesce(v_last::text, 'ไม่มี event เลย')
      USING ERRCODE = 'check_violation',
            HINT = 'ทุกการเปลี่ยนสถานะต้องมีแถว operation_event รองรับ';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_status_has_event
  AFTER INSERT OR UPDATE ON operation
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION f_status_has_event();

CREATE TABLE outbox (
  id           text PRIMARY KEY,
  operation_id text        NOT NULL REFERENCES operation(id) ON DELETE CASCADE,
  topic        text        NOT NULL CHECK (topic ~ '\.v[0-9]+$'),
  payload      jsonb       NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  sent_at      timestamptz
);
CREATE INDEX idx_outbox_pending ON outbox (created_at) WHERE sent_at IS NULL;

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
-- ====================  Group E · บันทึกการทำงาน  ======================
--
-- สามตารางต่อจากนี้ไม่ใช่ projection · ลบแล้ว replay ไม่ได้
-- และห้ามใส่ไว้ในสคริปต์ที่ลบ Group D เพื่อสร้างใหม่
-- ======================================================================

-- ปลายทางที่ร้านลงทะเบียนไว้
--
-- L6 analogue · ไม่เก็บ secret ในฐานข้อมูล เก็บแค่ reference ไปที่ KMS
-- CHECK บังคับรูปแบบของ reference เพื่อให้การเผลอยัด secret ดิบลงไปพังทันที
CREATE TABLE webhook_endpoint (
  id           text            PRIMARY KEY,
  merchant_id  text            NOT NULL REFERENCES merchant(id),
  url          text            NOT NULL CHECK (url ~ '^https://'),
  -- ตัวอย่าง 'kms://webhook/mch_a/v1' · ห้ามเป็นค่าความลับเอง
  secret_ref   text            NOT NULL CHECK (secret_ref ~ '^kms://'),
  -- cardinality ไม่ใช่ array_length
  --
  -- array_length(ARRAY[]::text[], 1) คืน NULL ไม่ใช่ 0
  -- และ CHECK ที่ได้ NULL ถือว่าผ่าน · array ว่างจึงเล็ดลอดไปได้
  -- cardinality คืน 0 ให้ array ว่าง ซึ่งเป็นสิ่งที่ต้องการ
  -- T16 จับข้อนี้ได้
  event_types  text[]          NOT NULL
                 CHECK (cardinality(event_types) >= 1
                        AND array_position(event_types, NULL) IS NULL),
  status       endpoint_status NOT NULL DEFAULT 'ACTIVE',
  max_attempts integer         NOT NULL DEFAULT 6 CHECK (max_attempts BETWEEN 1 AND 12),
  created_at   timestamptz     NOT NULL DEFAULT now(),
  -- http ธรรมดาไม่ได้ · ลายเซ็นกัน tamper ได้แต่ไม่กันการอ่าน
  CONSTRAINT ck_https_only CHECK (url NOT LIKE 'http://%')
);
CREATE INDEX ix_endpoint_merchant ON webhook_endpoint (merchant_id)
  WHERE status = 'ACTIVE';

-- ยิงไม่ได้ถ้า secret_ref ดูเหมือนค่าความลับ
CREATE OR REPLACE FUNCTION f_endpoint_no_plain_secret() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- reference ของ KMS ไม่มีเหตุผลที่จะยาวหรือดูเหมือน base64 ของ random
  IF length(NEW.secret_ref) > 200 THEN
    RAISE EXCEPTION 'secret_ref ยาวเกินไป · น่าจะเป็นค่าความลับเองไม่ใช่ reference'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.secret_ref ~ '^kms://[A-Za-z0-9/_.:+=-]+$' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'secret_ref ต้องเป็น kms:// ตามด้วย path ที่อ่านได้ · ได้ %',
    left(NEW.secret_ref, 40) USING ERRCODE = 'check_violation';
END $$;

CREATE TRIGGER trg_endpoint_no_plain_secret
  BEFORE INSERT OR UPDATE ON webhook_endpoint
  FOR EACH ROW EXECUTE FUNCTION f_endpoint_no_plain_secret();

-- งานส่งหนึ่งชิ้น · หนึ่ง event ไปหนึ่ง endpoint
--
-- delivery_seq เป็นลำดับต่อ (endpoint, operation)
-- ทำให้ร้านได้ event ของงานเดียวกันเรียงตามจริง ไม่ใช่สลับกัน
CREATE TABLE webhook_delivery (
  id              text            PRIMARY KEY,
  endpoint_id     text            NOT NULL REFERENCES webhook_endpoint(id),
  operation_id    text            NOT NULL REFERENCES operation(id),
  -- event ที่ทำให้เกิดการส่งนี้ · ชี้ตรงไปที่แถวใน operation_event
  event_seq       integer         NOT NULL CHECK (event_seq >= 1),
  delivery_seq    integer         NOT NULL CHECK (delivery_seq >= 1),
  event_type      text            NOT NULL,
  -- body ที่ส่งจริง · เก็บไว้เพื่อคำนวณลายเซ็นซ้ำและให้ร้านดูได้
  payload         jsonb           NOT NULL,
  signature       text            NOT NULL,
  signed_at       timestamptz     NOT NULL,
  status          delivery_status NOT NULL DEFAULT 'PENDING',
  attempt         integer         NOT NULL DEFAULT 0 CHECK (attempt >= 0),
  next_attempt_at timestamptz     NOT NULL DEFAULT now(),
  claimed_at      timestamptz,
  sent_at         timestamptz,
  dead_at         timestamptz,
  created_at      timestamptz     NOT NULL DEFAULT now(),
  -- การส่งซ้ำชี้กลับไปที่แถวเดิม · NULL = เป็นการส่งครั้งแรก
  replay_of       text,
  CONSTRAINT ck_delivery_sent  CHECK ((status = 'SENT') = (sent_at IS NOT NULL)),
  CONSTRAINT ck_delivery_dead  CHECK ((status = 'DEAD') = (dead_at IS NOT NULL)),
  CONSTRAINT ck_delivery_claim CHECK (status <> 'IN_FLIGHT' OR claimed_at IS NOT NULL),
  CONSTRAINT ck_no_self_replay CHECK (replay_of IS NULL OR replay_of <> id)
);
ALTER TABLE webhook_delivery
  ADD CONSTRAINT fk_replay_of FOREIGN KEY (replay_of) REFERENCES webhook_delivery(id);

-- ======================================================================
-- หนึ่ง event ส่งครั้งแรกได้ครั้งเดียวต่อ endpoint · การส่งซ้ำไม่นับ
--
-- ต้องเป็น partial index ไม่ใช่ unique เต็ม
--   unique เต็มจะทำให้ส่งซ้ำเป็นไปไม่ได้เลย เพราะแถวใหม่ใช้ event_seq เดิม
--   ยกเว้นแถวที่ replay_of มีค่า จึงยังรักษาข้อที่ต้องการไว้ได้
--   คือ "ไม่ยิง event เดียวซ้ำโดยไม่ได้ตั้งใจ"
-- ======================================================================
CREATE UNIQUE INDEX uq_delivery_event
  ON webhook_delivery (endpoint_id, operation_id, event_seq)
  WHERE replay_of IS NULL;
CREATE INDEX ix_delivery_replay ON webhook_delivery (replay_of)
  WHERE replay_of IS NOT NULL;
CREATE UNIQUE INDEX uq_delivery_seq
  ON webhook_delivery (endpoint_id, operation_id, delivery_seq);
-- คิวงาน · หยิบด้วย FOR UPDATE SKIP LOCKED
CREATE INDEX ix_delivery_due ON webhook_delivery (next_attempt_at)
  WHERE status = 'PENDING';
CREATE INDEX ix_delivery_dead ON webhook_delivery (dead_at) WHERE status = 'DEAD';

-- ======================================================================
-- การยิงหนึ่งครั้งและคำตอบที่ได้ · ตารางที่เป็น Group E ชัดที่สุด
--
-- ไม่มีค่าในตารางนี้แม้ค่าเดียวที่สืบกลับไปหา chain_event ได้
-- chain ไม่รู้ว่าร้านตอบ 500 · ไม่รู้ว่าใช้เวลา 3 วินาที · ไม่รู้ว่าลองครั้งที่ 4
-- และจะไม่มีวันรู้
-- ======================================================================
CREATE TABLE webhook_delivery_attempt (
  id              text        PRIMARY KEY,
  delivery_id     text        NOT NULL REFERENCES webhook_delivery(id) ON DELETE CASCADE,
  attempt         integer     NOT NULL CHECK (attempt >= 1),
  started_at      timestamptz NOT NULL,
  finished_at     timestamptz NOT NULL,
  response_status integer     CHECK (response_status IS NULL
                                     OR response_status BETWEEN 100 AND 599),
  response_body   text,
  error_note      text,
  CONSTRAINT ck_attempt_time CHECK (finished_at >= started_at),
  -- ต้องมีอย่างใดอย่างหนึ่ง · ยิงแล้วไม่ได้คำตอบและไม่มี error เป็นไปไม่ได้
  CONSTRAINT ck_attempt_outcome
    CHECK ((response_status IS NULL) <> (error_note IS NULL))
);
CREATE UNIQUE INDEX uq_attempt_seq ON webhook_delivery_attempt (delivery_id, attempt);

-- เวลาหน่วงแบบทวีคูณ · ครั้งที่ 1 รอ 1 นาที ครั้งที่ 6 รอ 32 นาที
CREATE OR REPLACE FUNCTION f_backoff(p_attempt integer) RETURNS interval
LANGUAGE sql IMMUTABLE AS $$
  SELECT least(power(2, greatest(p_attempt - 1, 0))::int, 60) * interval '1 minute'
$$;

-- ======================================================================
-- จำนวนครั้งที่ลองต้องตรงกับจำนวนแถว attempt ที่มีอยู่จริง
-- นับเองแล้วเขียนตัวเลขลงไปจะไม่ตรงเมื่อมีใครลืมเขียนแถว
-- ======================================================================
CREATE OR REPLACE FUNCTION f_attempt_count_matches() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_n integer; v_claimed integer;
BEGIN
  SELECT attempt INTO v_claimed FROM webhook_delivery WHERE id = NEW.delivery_id;
  SELECT count(*) INTO v_n FROM webhook_delivery_attempt WHERE delivery_id = NEW.delivery_id;
  IF v_claimed <> v_n THEN
    RAISE EXCEPTION 'delivery % บอกว่าลองไป % ครั้ง แต่มีแถว attempt % แถว',
      NEW.delivery_id, v_claimed, v_n
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_attempt_count_matches
  AFTER INSERT ON webhook_delivery_attempt
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION f_attempt_count_matches();

-- ======================================================================
-- จบแล้วจบเลย · SENT และ DEAD แก้ไม่ได้
--
-- ตารางนี้เป็นหลักฐานว่าเราส่งอะไรไปแล้ว · แก้ย้อนหลังได้ก็เลิกเป็นหลักฐาน
-- การส่งซ้ำคือการสร้างแถวใหม่ ไม่ใช่การปลุกแถวเดิม
-- ======================================================================
CREATE OR REPLACE FUNCTION f_delivery_terminal_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IN ('SENT','DEAD') THEN
    RAISE EXCEPTION 'delivery % จบที่ % ไปแล้ว แก้ไม่ได้ · ส่งซ้ำคือสร้างแถวใหม่',
      OLD.id, OLD.status USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.payload::text <> OLD.payload::text
     OR NEW.signature <> OLD.signature
     OR NEW.signed_at <> OLD.signed_at
     OR NEW.event_seq <> OLD.event_seq THEN
    RAISE EXCEPTION 'delivery % แก้เนื้อหาที่เซ็นไว้แล้วไม่ได้', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_delivery_terminal_immutable
  BEFORE UPDATE ON webhook_delivery
  FOR EACH ROW EXECUTE FUNCTION f_delivery_terminal_immutable();

-- ======================================================================
-- ส่งเรียงกันต่อหนึ่ง operation
--
-- ร้านที่ได้ FINALIZED ก่อน SUBMITTED จะสับสนมาก และถ้าร้านเขียนโค้ด
-- แบบตรงไปตรงมา มันจะเขียนสถานะทับด้วยค่าที่มาถึงทีหลัง ซึ่งผิด
--
-- ทางที่เลือก · บังคับให้ delivery ลำดับก่อนหน้าจบแล้ว (SENT หรือ DEAD)
-- ถึงจะเริ่มยิงลำดับถัดไปได้
--
-- ทางที่ไม่เลือก · ส่งขนานกันแล้วให้ร้านเรียงเอง
-- เพราะนั่นคือการย้ายปัญหาไปให้คนที่มีข้อมูลน้อยกว่าเรา
-- ======================================================================
CREATE OR REPLACE FUNCTION f_delivery_order_gate() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_prev delivery_status;
BEGIN
  IF NEW.status <> 'IN_FLIGHT' OR OLD.status = 'IN_FLIGHT' THEN RETURN NEW; END IF;
  IF NEW.delivery_seq = 1 THEN RETURN NEW; END IF;

  SELECT status INTO v_prev FROM webhook_delivery
   WHERE endpoint_id = NEW.endpoint_id
     AND operation_id = NEW.operation_id
     AND delivery_seq = NEW.delivery_seq - 1;

  IF v_prev IS NULL THEN RETURN NEW; END IF;
  IF v_prev NOT IN ('SENT','DEAD') THEN
    RAISE EXCEPTION 'delivery ลำดับ % ยิงไม่ได้ · ลำดับ % อยู่สถานะ %',
      NEW.delivery_seq, NEW.delivery_seq - 1, v_prev
      USING ERRCODE = 'check_violation',
            HINT = 'ส่ง event ของงานเดียวกันต้องเรียงตามลำดับ';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_delivery_order_gate
  BEFORE UPDATE ON webhook_delivery
  FOR EACH ROW EXECUTE FUNCTION f_delivery_order_gate();

-- ======================================================================
-- event_seq ที่อ้างถึงต้องมีอยู่จริงใน operation_event
--
-- foreign key ตรงๆ ทำไม่ได้เพราะ operation_event มี primary key เป็น id
-- แต่สิ่งที่ต้องการยึดคือ (operation_id, seq) · จึงตรวจด้วย trigger
-- ======================================================================
CREATE OR REPLACE FUNCTION f_delivery_event_exists() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM operation_event
                  WHERE operation_id = NEW.operation_id AND seq = NEW.event_seq) THEN
    RAISE EXCEPTION 'ไม่มี operation_event ของ % ที่ seq %',
      NEW.operation_id, NEW.event_seq
      USING ERRCODE = 'check_violation',
            HINT = 'ส่ง webhook เรื่องที่ไม่ได้เกิดขึ้นไม่ได้';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_delivery_event_exists
  BEFORE INSERT ON webhook_delivery
  FOR EACH ROW EXECUTE FUNCTION f_delivery_event_exists();

-- ======================================================================
-- ส่งซ้ำได้เฉพาะแถวที่ DEAD · และต้องเป็น event เดียวกันกับของเดิม
--
-- ส่งซ้ำแถวที่ SENT แปลว่าร้านจะได้ของเดิมสองครั้งโดยที่ไม่มีเหตุ
-- และถ้า event_seq ไม่ตรงกับของเดิม มันไม่ใช่การส่งซ้ำ มันคือการส่งเรื่องอื่น
-- ======================================================================
CREATE OR REPLACE FUNCTION f_replay_valid() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_st delivery_status; v_ep text; v_op text; v_seq integer;
BEGIN
  IF NEW.replay_of IS NULL THEN RETURN NEW; END IF;

  SELECT status, endpoint_id, operation_id, event_seq
    INTO v_st, v_ep, v_op, v_seq
    FROM webhook_delivery WHERE id = NEW.replay_of;

  IF v_st <> 'DEAD' THEN
    RAISE EXCEPTION 'ส่งซ้ำ % ไม่ได้ · แถวเดิมอยู่สถานะ % ไม่ใช่ DEAD',
      NEW.replay_of, v_st USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.endpoint_id <> v_ep OR NEW.operation_id <> v_op
     OR NEW.event_seq <> v_seq THEN
    RAISE EXCEPTION 'การส่งซ้ำต้องเป็น endpoint · operation · event เดียวกับของเดิม'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_replay_valid
  BEFORE INSERT ON webhook_delivery
  FOR EACH ROW EXECUTE FUNCTION f_replay_valid();

COMMIT;
