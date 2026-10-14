-- =====================================================================
-- FEAT-14 · Indexer + Projector · migration
-- อ่าน log จาก chain แล้วแปลงเป็นตารางที่ api อ่านได้
--
-- pack นี้เป็นฝั่งตรงข้ามของทุก pack ที่ผ่านมา
--   pack อื่น  เขียน operation แล้วยิง tx ออกไป
--   pack นี้   อ่านผลที่กลับมา แล้วเขียน projection
--
-- ======================================================================
-- สามข้อที่ pack นี้ต้องทำให้เป็นจริงในระดับ schema
--
--   L8          indexer รัน instance เดียว · cursor ขยับใน transaction
--               เดียวกับการ insert chain_event
--
--   RFD 5       reorg ตรวจด้วยการเทียบ block_hash ไม่ใช่นับความลึก
--
--   RFD 6 §3.2  projection ลบทิ้งแล้ว replay chain_event ใหม่
--               ต้องได้ค่าเดิมเป๊ะ
--
-- ข้อที่สามเป็นข้อที่ทุก pack ก่อนหน้าอ้างถึงแต่ไม่มีใครพิสูจน์
-- pack นี้พิสูจน์ด้วยการทำจริง · T20 ถึง T23
-- ======================================================================
--
-- อ้างอิง  L8 · RFD 1 §10 (คำถาม N block) · RFD 5 · RFD 6 §3.2
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

CREATE TYPE holder_kind AS ENUM ('MERCHANT', 'CUSTOMER');
CREATE TYPE merchant_status AS ENUM ('PENDING','ACTIVE','SUSPENDED','CLOSED');
CREATE TYPE coupon_code_state AS ENUM ('ISSUED','HELD','REDEEMED','EXPIRED','VOIDED');

-- ชนิดของ event ที่ indexer รู้จักถอดรหัส
-- ชนิดที่ไม่รู้จักยังถูกเก็บ แต่ไม่ถูก apply · ดู f_apply_event
CREATE TYPE chain_event_name AS ENUM (
  'CouponTransfer',   -- คูปองย้ายมือ
  'PointTransfer',    -- point ย้ายมือ
  'CouponRedeemed',   -- คูปองถูกใช้
  'UNKNOWN'           -- topic0 ที่ยังไม่รู้จัก
);

CREATE TYPE reorg_outcome AS ENUM (
  'ROLLED_BACK',   -- ลึกน้อยกว่า N · ย้อน projection แล้วอ่านใหม่ได้
  'MANUAL_REVIEW'  -- ลึกกว่า N · มี event ที่ถือว่า final แล้วหลุด
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

CREATE TABLE point_type (
  id          text PRIMARY KEY,
  merchant_id text NOT NULL REFERENCES merchant(id),
  name        text NOT NULL
);

CREATE TABLE coupon_type (
  id          text PRIMARY KEY,
  merchant_id text NOT NULL REFERENCES merchant(id),
  name        text NOT NULL
);

CREATE TABLE coupon_code (
  id             text PRIMARY KEY,
  coupon_type_id text              NOT NULL REFERENCES coupon_type(id),
  -- RFD 12 · chain รู้จักคูปองด้วย code_ref ไม่ใช่ด้วย id
  code_ref       bytea             NOT NULL CHECK (octet_length(code_ref) = 32),
  state          coupon_code_state NOT NULL DEFAULT 'ISSUED'
);
CREATE UNIQUE INDEX uq_code_ref ON coupon_code (code_ref);

-- --------------------------------------------- Group B (เท่าที่ต้องใช้)
CREATE TABLE operation (
  id           text PRIMARY KEY,
  actor_scope  text             NOT NULL,
  kind         operation_kind   NOT NULL,
  status       operation_status NOT NULL DEFAULT 'PENDING',
  payload      jsonb            NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz      NOT NULL DEFAULT now(),
  finalized_at timestamptz,
  CONSTRAINT ck_finalized_consistent
    CHECK ((status = 'FINALIZED') = (finalized_at IS NOT NULL))
);

-- ======================================================================
-- ความลึกที่ถือว่าจบ · คำถามที่ RFD 1 §10 ค้างไว้
--
-- เก็บเป็นตารางที่มี effective_from ไม่ใช่ค่าคงที่ในโค้ด เพราะ
--   1 · ค่านี้ขึ้นกับ chain ที่ใช้ และอาจเปลี่ยนเมื่อย้าย chain
--   2 · เปลี่ยนค่าวันนี้ต้องไม่ทำให้ event ที่เคยถือว่า final กลายเป็นไม่ final
--       f_finality_depth(ts) จึงตอบตามเวลาที่ถาม
--
-- ค่าตั้งต้น 12 บล็อก · ยังไม่ผ่านการยืนยันกับทีม chain
-- และ pack นี้ไม่ได้ตอบว่า 12 ถูกหรือผิด · ตอบแค่ว่าค่านี้อยู่ที่เดียว
-- และเปลี่ยนแล้วไม่ทำลายอดีต
-- ======================================================================
CREATE TABLE finality_config (
  id             text        PRIMARY KEY,
  depth_blocks   integer     NOT NULL CHECK (depth_blocks BETWEEN 1 AND 1000),
  effective_from timestamptz NOT NULL,
  note           text
);
CREATE UNIQUE INDEX uq_finality_effective ON finality_config (effective_from);

CREATE OR REPLACE FUNCTION f_finality_depth(p_at timestamptz) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT depth_blocks FROM finality_config
   WHERE effective_from <= p_at
   ORDER BY effective_from DESC LIMIT 1
$$;

-- ======================================================================
-- cursor · แถวเดียวเท่านั้น และมี lease
--
-- L8 ข้อแรก · indexer รัน instance เดียว
--
-- สองชั้นที่ใช้ร่วมกัน
--   pg_advisory_lock  กันสอง process ในเวลาเดียวกัน · เร็วและชัด
--   lease_until       กัน process ที่ค้างอยู่แล้วเครื่องตาย โดยที่ lock หลุดไปแล้ว
--
-- advisory lock หายไปเมื่อ connection ตาย ซึ่งเป็นสิ่งที่ต้องการ
-- แต่ไม่พอ เพราะ process ที่ยังไม่ตายแต่หยุดตอบสนอง จะถือ lock ไว้
-- lease จึงเป็นตัวบอกว่า "ถือไว้นานเกินไปแล้ว ปล่อยได้"
-- ======================================================================
CREATE TABLE indexer_cursor (
  id              text        PRIMARY KEY CHECK (id = 'main'),
  last_block      bigint      NOT NULL CHECK (last_block >= 0),
  last_block_hash bytea       CHECK (last_block_hash IS NULL
                                     OR octet_length(last_block_hash) = 32),
  lease_owner     text,
  lease_until     timestamptz,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_lease_pair CHECK ((lease_owner IS NULL) = (lease_until IS NULL)),
  -- บล็อกที่ศูนย์คือ "ยังไม่เริ่มอ่าน" จึงยังไม่มี hash
  CONSTRAINT ck_cursor_hash CHECK ((last_block = 0) = (last_block_hash IS NULL))
);

-- cursor ขยับได้เฉพาะคนที่ถือ lease อยู่ และ lease ยังไม่หมดอายุ
CREATE OR REPLACE FUNCTION f_cursor_needs_lease() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- การขอหรือปล่อย lease ไม่นับเป็นการขยับ cursor
  IF NEW.last_block = OLD.last_block THEN RETURN NEW; END IF;

  IF NEW.lease_owner IS NULL THEN
    RAISE EXCEPTION 'ขยับ cursor ไม่ได้ · ไม่มีใครถือ lease'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.lease_until <= now() THEN
    RAISE EXCEPTION 'ขยับ cursor ไม่ได้ · lease ของ % หมดอายุไปแล้ว', NEW.lease_owner
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.lease_owner IS DISTINCT FROM OLD.lease_owner THEN
    RAISE EXCEPTION 'เปลี่ยนเจ้าของ lease พร้อมกับขยับ cursor ไม่ได้'
      USING ERRCODE = 'check_violation',
            HINT = 'ขอ lease ก่อน แล้วค่อยขยับในสเตตเมนต์ถัดไป';
  END IF;
  -- cursor ถอยหลังได้เฉพาะตอนจัดการ reorg · ดู f_rewind_for_reorg
  IF NEW.last_block < OLD.last_block
     AND NOT coalesce(current_setting('app.reorg_in_progress', true)::boolean, false) THEN
    RAISE EXCEPTION 'cursor ถอยจาก % ไป % ไม่ได้ · ถอยได้เฉพาะตอนจัดการ reorg',
      OLD.last_block, NEW.last_block
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_cursor_needs_lease
  BEFORE UPDATE ON indexer_cursor
  FOR EACH ROW EXECUTE FUNCTION f_cursor_needs_lease();

-- ======================================================================
-- บล็อกที่อ่านมาแล้ว · ต้องต่อกันเป็นสายโซ่
--
-- RFD 5 · reorg ตรวจด้วยการเทียบ block_hash ไม่ใช่นับความลึก
--
-- trigger ข้างล่างทำให้ "สายโซ่ที่ขาด" เก็บลงฐานข้อมูลไม่ได้เลย
-- ไม่ใช่เก็บได้แล้วค่อยมีใครมาตรวจทีหลัง
-- ถ้า parent_hash ไม่ตรงกับ block_hash ของบล็อกก่อนหน้า นั่นคือ reorg
-- และต้องจัดการ reorg ก่อน ถึงจะเขียนบล็อกใหม่ได้
-- ======================================================================
-- ======================================================================
-- primary key เป็น block_hash ไม่ใช่ block_number
--
-- ตัวตนของบล็อกคือ hash ของมัน · ความสูงไม่ใช่ตัวตน
-- หลัง reorg จะมีบล็อกสองใบที่ความสูงเดียวกัน ใบหนึ่ง orphan ใบหนึ่งอยู่บนสายหลัก
-- ถ้า block_number เป็น primary key เรื่องนั้นเป็นไปไม่ได้ และ reorg
-- จะเก็บประวัติไม่ได้เลย — ต้องลบของเก่าทิ้ง ซึ่งทำให้สืบย้อนไม่ได้
--
-- รอบแรกเขียน block_number เป็น primary key และ T26 จับได้
-- ======================================================================
CREATE TABLE raw_block (
  block_hash   bytea       PRIMARY KEY CHECK (octet_length(block_hash) = 32),
  block_number bigint      NOT NULL CHECK (block_number > 0),
  parent_hash  bytea       NOT NULL CHECK (octet_length(parent_hash) = 32),
  timestamp    timestamptz NOT NULL,
  tx_count     integer     NOT NULL DEFAULT 0 CHECK (tx_count >= 0),
  orphaned_at  timestamptz,
  read_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_not_own_parent CHECK (block_hash <> parent_hash)
);
-- หนึ่งความสูงมีบล็อกบนสายหลักได้ใบเดียว · ที่ orphan แล้วมีได้หลายใบ
CREATE UNIQUE INDEX uq_block_live ON raw_block (block_number)
  WHERE orphaned_at IS NULL;
CREATE INDEX ix_block_number ON raw_block (block_number);
CREATE INDEX ix_block_orphaned ON raw_block (orphaned_at)
  WHERE orphaned_at IS NOT NULL;

CREATE OR REPLACE FUNCTION f_block_links_to_parent() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_prev_hash bytea;
BEGIN
  IF NEW.orphaned_at IS NOT NULL THEN RETURN NEW; END IF;

  SELECT block_hash INTO v_prev_hash FROM raw_block
   WHERE block_number = NEW.block_number - 1 AND orphaned_at IS NULL;

  -- ยังไม่มีบล็อกก่อนหน้า · เริ่มอ่านจากจุดนี้ ไม่มีอะไรให้เทียบ
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF NEW.parent_hash <> v_prev_hash THEN
    RAISE EXCEPTION 'บล็อก % ชี้ไป parent % แต่บล็อก % ที่มีอยู่คือ %',
      NEW.block_number, encode(NEW.parent_hash,'hex'),
      NEW.block_number - 1, encode(v_prev_hash,'hex')
      USING ERRCODE = 'check_violation',
            HINT = 'นี่คือ reorg · ต้อง orphan บล็อกเก่าก่อน แล้วค่อยเขียนบล็อกใหม่';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_block_links_to_parent
  BEFORE INSERT ON raw_block
  FOR EACH ROW EXECUTE FUNCTION f_block_links_to_parent();

-- ======================================================================
-- log ที่อ่านมา
--
-- UNIQUE (tx_hash, log_index) ทำให้อ่านช่วงเดิมซ้ำปลอดภัย
-- ซึ่งจำเป็น เพราะ indexer ที่ restart จะอ่านทับช่วงเดิมเสมอ
--
-- data เป็นของจริงที่ได้จาก chain · args เป็นผลของการถอดรหัส
-- ถ้าสองค่าไม่ตรงกัน data ถูก · args เป็นแคชที่สร้างใหม่ได้
-- ======================================================================
CREATE TABLE chain_event (
  id              text             PRIMARY KEY,
  block_number    bigint           NOT NULL,
  block_hash      bytea            NOT NULL CHECK (octet_length(block_hash) = 32),
  tx_hash         bytea            NOT NULL CHECK (octet_length(tx_hash) = 32),
  log_index       integer          NOT NULL CHECK (log_index >= 0),
  address         bytea            NOT NULL CHECK (octet_length(address) = 20),
  topic0          bytea            NOT NULL CHECK (octet_length(topic0) = 32),
  topics          jsonb            NOT NULL DEFAULT '[]'::jsonb,
  data            bytea            NOT NULL,
  block_timestamp timestamptz      NOT NULL,
  event_name      chain_event_name NOT NULL DEFAULT 'UNKNOWN',
  args            jsonb,
  operation_id    text             REFERENCES operation(id),
  applied_at      timestamptz,
  orphaned_at     timestamptz,
  -- ที่รู้ว่า final แล้ว · เขียนเมื่อ cursor ผ่านไปลึกพอ
  finalized_at    timestamptz,
  CONSTRAINT ck_known_has_args
    CHECK (event_name = 'UNKNOWN' OR args IS NOT NULL),
  -- orphan แล้วจะ applied ไม่ได้ · ต้องย้อน projection ก่อน
  CONSTRAINT ck_orphan_not_applied
    CHECK (orphaned_at IS NULL OR applied_at IS NULL)
);
CREATE UNIQUE INDEX uq_chain_event ON chain_event (tx_hash, log_index);
-- คิวของ projector · เรียงตามลำดับบน chain เป๊ะ
CREATE INDEX ix_event_unapplied ON chain_event (block_number, log_index)
  WHERE applied_at IS NULL AND orphaned_at IS NULL;
CREATE INDEX ix_event_by_block ON chain_event (block_number);
CREATE INDEX ix_event_not_final ON chain_event (block_number)
  WHERE finalized_at IS NULL AND orphaned_at IS NULL;

ALTER TABLE chain_event
  ADD CONSTRAINT fk_event_block FOREIGN KEY (block_hash) REFERENCES raw_block(block_hash);

-- ======================================================================
-- L8 ข้อที่สอง · cursor ขยับใน transaction เดียวกับการ insert chain_event
--
-- เขียนเป็นกฎที่ตรวจได้ว่า **ไม่มี chain_event ที่ block_number เกิน cursor**
--
-- ถ้ามี แปลว่ามีใคร insert event แล้วไม่ขยับ cursor ใน transaction เดียวกัน
-- ซึ่งคือสิ่งที่ L8 ห้าม · และผลคือ indexer ที่ restart จะอ่านช่วงนั้นใหม่
-- แล้วเจอ event ที่มีอยู่แล้ว ซึ่งปลอดภัยเพราะ UNIQUE แต่สถานะจะสับสน
--
-- ตรวจตอน COMMIT เพราะลำดับการเขียนไม่แน่ · บางที่ขยับ cursor ก่อน
-- บางที่ insert event ก่อน ทั้งสองแบบถูก ขอแค่ตอน COMMIT มันสอดคล้อง
-- ======================================================================
CREATE OR REPLACE FUNCTION f_event_within_cursor() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_last bigint; v_max bigint;
BEGIN
  SELECT last_block INTO v_last FROM indexer_cursor WHERE id = 'main';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่มีแถว indexer_cursor · ต้องสร้างก่อนเริ่มอ่าน'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT max(block_number) INTO v_max FROM chain_event WHERE orphaned_at IS NULL;
  IF v_max IS NOT NULL AND v_max > v_last THEN
    RAISE EXCEPTION 'มี chain_event ที่บล็อก % แต่ cursor อยู่ที่ %', v_max, v_last
      USING ERRCODE = 'check_violation',
            HINT = 'L8 · cursor ต้องขยับใน transaction เดียวกับการ insert event';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_event_within_cursor
  AFTER INSERT OR UPDATE ON chain_event
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION f_event_within_cursor();

-- ======================================================================
-- event ที่ final แล้ว orphan ไม่ได้
--
-- นี่คือความหมายที่แท้จริงของการมีค่า N
-- ถ้า event ที่เคยบอกลูกค้าว่าเสร็จแล้วยังหลุดได้ ค่า N ก็ไม่มีความหมาย
--
-- reorg ที่ลึกกว่า N เป็นเหตุการณ์ที่ต้องมีคนดู ไม่ใช่เหตุการณ์ที่โค้ดจัดการเอง
-- จึงไม่ยอมให้เขียน และบังคับให้ไปทาง MANUAL_REVIEW
-- ======================================================================
CREATE OR REPLACE FUNCTION f_final_not_orphanable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.orphaned_at IS NOT NULL AND OLD.finalized_at IS NOT NULL THEN
    RAISE EXCEPTION 'event % ถือว่า final ไปแล้วตั้งแต่ % · orphan ไม่ได้',
      NEW.id, OLD.finalized_at
      USING ERRCODE = 'check_violation',
            HINT = 'reorg ที่ลึกกว่า N ต้องไป MANUAL_REVIEW ไม่ใช่ย้อนเงียบๆ';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_final_not_orphanable
  BEFORE UPDATE ON chain_event
  FOR EACH ROW EXECUTE FUNCTION f_final_not_orphanable();

-- ======================================================================
-- ====================  Group D · projection  ==========================
--
-- RFD 6 §3.2 · ลบทิ้งทั้งตาราง แล้ว replay chain_event ใหม่
-- ต้องได้ค่าเดิมเป๊ะ
--
-- สองตารางข้างล่างต้องผ่านข้อนี้ และ T20 ถึง T23 พิสูจน์ด้วยการทำจริง
--
-- กฎที่ตามมาจากข้อนี้ และสำคัญกว่าที่เห็น
--   ห้ามมีคอลัมน์ที่ค่ามาจากเวลาที่ apply · ต้องมาจากเวลาของบล็อกเท่านั้น
--   now() ในตารางพวกนี้ทำให้ replay ได้ค่าไม่เหมือนเดิมทันที
-- ======================================================================
CREATE TABLE coupon_holding (
  coupon_code_id text        PRIMARY KEY REFERENCES coupon_code(id),
  holder_kind    holder_kind NOT NULL,
  holder_id      text        NOT NULL,
  -- เวลาของบล็อก ไม่ใช่เวลาที่ apply · ถ้าใช้ now() replay จะได้ค่าต่าง
  as_of_block    bigint      NOT NULL,
  as_of_time     timestamptz NOT NULL
);
CREATE INDEX ix_holding_holder ON coupon_holding (holder_kind, holder_id);

CREATE TABLE point_balance (
  point_type_id text          NOT NULL REFERENCES point_type(id),
  holder_kind   holder_kind   NOT NULL,
  holder_id     text          NOT NULL,
  amount        numeric(78,0) NOT NULL CHECK (amount >= 0),
  as_of_block   bigint        NOT NULL,
  PRIMARY KEY (point_type_id, holder_kind, holder_id)
);

-- ======================================================================
-- บันทึก reorg ที่จัดการไปแล้ว · Group E (ตาม FEAT-13)
--
-- ลบแล้ว replay ไม่ได้ · เพราะมันบันทึกสิ่งที่ chain ไม่เคยบอก
-- คือ "เราเคยเชื่ออะไรไปแล้วและเปลี่ยนใจเมื่อไร"
-- ======================================================================
CREATE TABLE reorg_log (
  id              text          PRIMARY KEY,
  detected_at     timestamptz   NOT NULL DEFAULT now(),
  fork_block      bigint        NOT NULL CHECK (fork_block > 0),
  old_tip         bigint        NOT NULL,
  depth           integer       NOT NULL CHECK (depth >= 1),
  finality_depth  integer       NOT NULL,
  orphaned_events integer       NOT NULL CHECK (orphaned_events >= 0),
  outcome         reorg_outcome NOT NULL,
  note            text,
  CONSTRAINT ck_depth_matches CHECK (depth = old_tip - fork_block + 1)
);
CREATE INDEX ix_reorg_review ON reorg_log (detected_at)
  WHERE outcome = 'MANUAL_REVIEW';

-- ผลลัพธ์ต้องตรงกับความลึกจริง · เลือกเองไม่ได้ (แบบเดียวกับ FEAT-12)
CREATE OR REPLACE FUNCTION f_reorg_outcome_matches_depth() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.depth > NEW.finality_depth AND NEW.outcome <> 'MANUAL_REVIEW' THEN
    RAISE EXCEPTION 'reorg ลึก % เกิน N = % · ต้องเป็น MANUAL_REVIEW',
      NEW.depth, NEW.finality_depth USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.depth <= NEW.finality_depth AND NEW.outcome <> 'ROLLED_BACK' THEN
    RAISE EXCEPTION 'reorg ลึก % ไม่เกิน N = % · ย้อนเองได้ ต้องเป็น ROLLED_BACK',
      NEW.depth, NEW.finality_depth USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_reorg_outcome_matches_depth
  BEFORE INSERT ON reorg_log
  FOR EACH ROW EXECUTE FUNCTION f_reorg_outcome_matches_depth();

-- ======================================================================
-- ====================  ตัว projector  =================================
--
-- ฟังก์ชันเดียวที่แปลง event หนึ่งแถวเป็นการเปลี่ยน projection
--
-- เขียนเป็นฟังก์ชันในฐานข้อมูลโดยตั้งใจ ไม่ใช่ในโค้ด เพราะ
--   การ replay ต้องใช้ตรรกะเดียวกับการ apply ครั้งแรก เป๊ะ
--   ถ้าตรรกะอยู่ในโค้ด การ replay จะต้องรันโค้ดรุ่นเดียวกับที่ apply ครั้งแรก
--   ซึ่งเป็นไปไม่ได้เมื่อเวลาผ่านไปและโค้ดเปลี่ยน
--
--   อยู่ในฐานข้อมูล แปลว่า replay ใช้ตรรกะที่อยู่ในฐานข้อมูลตอนนั้น
--   ซึ่งยังเป็นปัญหาเดียวกันในทางทฤษฎี แต่เล็กกว่ามากในทางปฏิบัติ
--   และทำให้ T20 ถึง T23 ทดสอบสิ่งที่ production ทำจริงได้
-- ======================================================================
CREATE OR REPLACE FUNCTION f_apply_event(p_event_id text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
  e            chain_event;
  v_code       text;
  v_pt         text;
  v_to_kind    holder_kind;
  v_to_id      text;
  v_from_kind  holder_kind;
  v_from_id    text;
  v_amount     numeric;
BEGIN
  SELECT * INTO e FROM chain_event WHERE id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบ chain_event %', p_event_id USING ERRCODE = 'check_violation';
  END IF;
  IF e.orphaned_at IS NOT NULL THEN RETURN false; END IF;
  IF e.applied_at IS NOT NULL THEN RETURN false; END IF;

  CASE e.event_name

    WHEN 'CouponTransfer' THEN
      SELECT id INTO v_code FROM coupon_code
       WHERE code_ref = decode(e.args->>'codeRef', 'hex');
      IF NOT FOUND THEN
        RAISE EXCEPTION 'event % อ้าง code_ref ที่ไม่มีในระบบ', p_event_id
          USING ERRCODE = 'check_violation';
      END IF;
      v_to_kind := (e.args->>'toKind')::holder_kind;
      v_to_id   := e.args->>'toId';

      INSERT INTO coupon_holding (coupon_code_id, holder_kind, holder_id,
                                  as_of_block, as_of_time)
      VALUES (v_code, v_to_kind, v_to_id, e.block_number, e.block_timestamp)
      ON CONFLICT (coupon_code_id) DO UPDATE
        SET holder_kind = EXCLUDED.holder_kind,
            holder_id   = EXCLUDED.holder_id,
            as_of_block = EXCLUDED.as_of_block,
            as_of_time  = EXCLUDED.as_of_time;

    WHEN 'PointTransfer' THEN
      v_pt        := e.args->>'pointTypeId';
      v_amount    := (e.args->>'amount')::numeric;
      v_to_kind   := (e.args->>'toKind')::holder_kind;
      v_to_id     := e.args->>'toId';

      -- ฝั่งรับ
      INSERT INTO point_balance (point_type_id, holder_kind, holder_id, amount, as_of_block)
      VALUES (v_pt, v_to_kind, v_to_id, v_amount, e.block_number)
      ON CONFLICT (point_type_id, holder_kind, holder_id) DO UPDATE
        SET amount = point_balance.amount + v_amount,
            as_of_block = EXCLUDED.as_of_block;

      -- ฝั่งจ่าย · address ศูนย์ = mint ไม่มีคนจ่าย
      IF e.args ? 'fromId' AND e.args->>'fromId' <> '' THEN
        v_from_kind := (e.args->>'fromKind')::holder_kind;
        v_from_id   := e.args->>'fromId';
        UPDATE point_balance
           SET amount = amount - v_amount, as_of_block = e.block_number
         WHERE point_type_id = v_pt AND holder_kind = v_from_kind
           AND holder_id = v_from_id;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'event % จ่าย point จากบัญชีที่ไม่มียอด', p_event_id
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

    WHEN 'CouponRedeemed' THEN
      SELECT id INTO v_code FROM coupon_code
       WHERE code_ref = decode(e.args->>'codeRef', 'hex');
      IF NOT FOUND THEN
        RAISE EXCEPTION 'event % อ้าง code_ref ที่ไม่มีในระบบ', p_event_id
          USING ERRCODE = 'check_violation';
      END IF;
      UPDATE coupon_code SET state = 'REDEEMED' WHERE id = v_code;
      DELETE FROM coupon_holding WHERE coupon_code_id = v_code;

    ELSE
      -- ชนิดที่ยังไม่รู้จัก · เก็บไว้แต่ไม่แตะ projection
      -- ทำเครื่องหมายว่า apply แล้ว เพื่อไม่ให้ค้างในคิวตลอดไป
      NULL;
  END CASE;

  UPDATE chain_event SET applied_at = now() WHERE id = p_event_id;
  RETURN true;
END $$;

-- ======================================================================
-- apply ตามลำดับบน chain เป๊ะ
--
-- (block_number, log_index) คือลำดับจริง และต้องเรียงตามนี้
-- สลับลำดับของ PointTransfer สองแถวในบล็อกเดียว อาจทำให้ยอดติดลบกลางทาง
-- แล้ว CHECK (amount >= 0) จะปฏิเสธ ทั้งที่ผลสุดท้ายถูก
-- ======================================================================
CREATE OR REPLACE FUNCTION f_apply_pending(p_limit integer DEFAULT 1000)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN
    SELECT id FROM chain_event
     WHERE applied_at IS NULL AND orphaned_at IS NULL
     ORDER BY block_number, log_index
     LIMIT p_limit
  LOOP
    IF f_apply_event(r.id) THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$;

-- ======================================================================
-- RFD 6 §3.2 ในรูปของฟังก์ชันที่รันได้
--
-- ลบ projection ทั้งหมด · ล้าง applied_at · แล้ว apply ใหม่ทั้งหมด
-- ผลที่ได้ต้องเท่ากับก่อนลบ และ T20 ถึง T23 ตรวจข้อนั้น
--
-- ไม่แตะ Group E (reorg_log) และไม่แตะ chain_event เอง นอกจาก applied_at
-- ======================================================================
CREATE OR REPLACE FUNCTION f_replay_projections() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  DELETE FROM coupon_holding;
  DELETE FROM point_balance;
  -- state ของ coupon_code เป็น projection ด้วย · ต้องย้อนกลับไปค่าตั้งต้น
  UPDATE coupon_code SET state = 'ISSUED' WHERE state = 'REDEEMED';
  UPDATE chain_event SET applied_at = NULL WHERE orphaned_at IS NULL;

  n := f_apply_pending(1000000);
  RETURN n;
END $$;

-- ======================================================================
-- ย้อน projection สำหรับ reorg
--
-- ไม่พยายามย้อนทีละ event แบบย้อนกลับ เพราะ event บางชนิดย้อนไม่ได้
-- ตรงๆ (CouponRedeemed ลบแถว · จะรู้ได้อย่างไรว่าเดิมใครถือ)
--
-- จึง orphan event ที่หลุด แล้ว replay ทั้งหมดใหม่
-- ช้ากว่า แต่ถูกเสมอ และใช้ตรรกะเดียวกับ apply ปกติ
-- ซึ่งแปลว่าไม่มีโค้ดเส้นที่สองที่ต้องดูแลให้ตรงกับเส้นแรก
-- ======================================================================
CREATE OR REPLACE FUNCTION f_handle_reorg(
  p_fork_block bigint, p_owner text
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_tip bigint; v_depth integer; v_n integer; v_final integer;
  v_outcome reorg_outcome; v_id text; v_stuck integer;
BEGIN
  SELECT last_block INTO v_tip FROM indexer_cursor WHERE id = 'main';
  IF p_fork_block > v_tip THEN
    RAISE EXCEPTION 'fork block % อยู่หลัง tip % · ไม่ใช่ reorg', p_fork_block, v_tip
      USING ERRCODE = 'check_violation';
  END IF;

  v_depth := v_tip - p_fork_block + 1;
  v_final := f_finality_depth(now());

  -- มี event ที่ถือว่า final แล้วอยู่ในช่วงที่จะหลุดหรือไม่
  SELECT count(*) INTO v_stuck FROM chain_event
   WHERE block_number >= p_fork_block AND orphaned_at IS NULL
     AND finalized_at IS NOT NULL;

  IF v_depth > v_final OR v_stuck > 0 THEN
    v_outcome := 'MANUAL_REVIEW';
  ELSE
    v_outcome := 'ROLLED_BACK';
  END IF;

  SELECT count(*) INTO v_n FROM chain_event
   WHERE block_number >= p_fork_block AND orphaned_at IS NULL;

  v_id := 'rg_' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS');
  INSERT INTO reorg_log (id, fork_block, old_tip, depth, finality_depth,
                         orphaned_events, outcome,
                         note)
  VALUES (v_id, p_fork_block, v_tip, v_depth, v_final, v_n, v_outcome,
          CASE WHEN v_stuck > 0
               THEN 'มี event ที่ final แล้ว ' || v_stuck || ' แถวอยู่ในช่วงที่หลุด'
               ELSE NULL END);

  IF v_outcome = 'MANUAL_REVIEW' THEN
    -- ไม่แตะอะไรเลย · ปล่อยให้คนตัดสิน
    RETURN v_id;
  END IF;

  -- ย้อนได้ · ต้องล้าง applied_at ก่อน เพราะ ck_orphan_not_applied
  UPDATE chain_event SET applied_at = NULL
   WHERE block_number >= p_fork_block AND orphaned_at IS NULL;
  UPDATE chain_event SET orphaned_at = now()
   WHERE block_number >= p_fork_block AND orphaned_at IS NULL;
  UPDATE raw_block SET orphaned_at = now()
   WHERE block_number >= p_fork_block AND orphaned_at IS NULL;

  -- ถอย cursor · ต้องบอกว่ากำลังจัดการ reorg ไม่งั้น trigger ไม่ยอม
  PERFORM set_config('app.reorg_in_progress', 'true', true);
  UPDATE indexer_cursor
     SET last_block = p_fork_block - 1,
         last_block_hash = (SELECT block_hash FROM raw_block
                             WHERE block_number = p_fork_block - 1
                               AND orphaned_at IS NULL),
         updated_at = now()
   WHERE id = 'main';
  PERFORM set_config('app.reorg_in_progress', 'false', true);

  PERFORM f_replay_projections();
  RETURN v_id;
END $$;

-- ======================================================================
-- ทำเครื่องหมายว่า final · เรียกหลังขยับ cursor
-- event ที่ลึกกว่า N บล็อกจาก tip ถือว่าจบ และ orphan ไม่ได้อีก
-- ======================================================================
CREATE OR REPLACE FUNCTION f_mark_finalized() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_tip bigint; v_depth integer; v_n integer;
BEGIN
  SELECT last_block INTO v_tip FROM indexer_cursor WHERE id = 'main';
  v_depth := f_finality_depth(now());

  UPDATE chain_event SET finalized_at = now()
   WHERE finalized_at IS NULL AND orphaned_at IS NULL
     AND applied_at IS NOT NULL
     AND block_number <= v_tip - v_depth;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

COMMIT;
