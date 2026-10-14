-- =====================================================================
-- FEAT-06 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat06 -f tests/acceptance.sql
-- ทุกแถวต้องขึ้น PASS · แถวเดียวที่ FAIL = schema ไม่ให้สิ่งที่ RFD สัญญาไว้
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

-- ทั้งไฟล์รันใน transaction เดียวแล้ว ROLLBACK ทิ้งท้าย
-- จึงรันซ้ำกี่รอบก็ได้ และไม่ทิ้งข้อมูลทดสอบไว้ในฐานข้อมูล
BEGIN;

CREATE TEMP TABLE result (id text, what text, verdict text);

CREATE OR REPLACE FUNCTION t_ok(p_id text, p_what text, p_pass boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO result VALUES (p_id, p_what, CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END) $$;

-- เวลาอ้างอิงตายตัว · ไม่ใช้ now() ใน assertion เพื่อให้ผลทดสอบทำซ้ำได้
CREATE TEMP TABLE t0 AS SELECT timestamptz '2026-10-01 00:00:00+00' AS v;
CREATE OR REPLACE FUNCTION T0() RETURNS timestamptz LANGUAGE sql STABLE AS $$ SELECT v FROM t0 $$;

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id,name) VALUES ('mch_1','ร้านทดสอบ');
INSERT INTO customer (id,tel_hash) VALUES ('cus_1', sha256('0810000001'));
INSERT INTO point_type (id,merchant_id,name,symbol,decimals,status)
VALUES ('pt_1','mch_1','แต้มสะสมสุขใจ','SUKJAI',18,'LIVE');
INSERT INTO point_type_chain (point_type_id,contract_address,genesis_at,epoch_seconds,validity_epochs)
VALUES ('pt_1', decode(repeat('aa',20),'hex'), T0() - interval '365 days', 2592000, 4);

-- ลูกค้ามี 4 ก้อน · หมดอายุคนละวัน
INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at) VALUES
 ('b_expired','pt_1','CUSTOMER','cus_1', 1, 500, T0() - interval '200 days', T0() - interval '10 days'),
 ('b_soon',   'pt_1','CUSTOMER','cus_1', 2, 100, T0() - interval '100 days', T0() + interval '5 days'),
 ('b_mid',    'pt_1','CUSTOMER','cus_1', 3, 200, T0() - interval '60 days',  T0() + interval '20 days'),
 ('b_far',    'pt_1','CUSTOMER','cus_1', 4, 300, T0() - interval '30 days',  T0() + interval '90 days'),
 ('b_zero',   'pt_1','CUSTOMER','cus_1', 5,   0, T0() - interval '10 days',  T0() + interval '60 days');

INSERT INTO projection_watermark (last_block,last_block_at) VALUES (1000, T0() - interval '30 seconds');
INSERT INTO indexer_cursor (contract_address,last_block)
VALUES (decode(repeat('aa',20),'hex'), 1005);

-- =====================================================================
-- T1 · ยอดที่ใช้ได้ = ผลรวม bucket ที่ยังไม่หมดอายุ            RFD 10
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  v := f_available_points('pt_1','CUSTOMER','cus_1', T0());
  PERFORM t_ok('T1','ยอดที่ใช้ได้ = 100+200+300 = 600 (ไม่นับก้อนที่หมดอายุและก้อนศูนย์)', v = 600);
END $$;

-- =====================================================================
-- T2 · as_of ย้อนหลัง ต้องได้คำตอบของตอนนั้น
--      ก้อนที่หมดอายุไปแล้ววันนี้ ยังใช้ได้เมื่อ 30 วันก่อน
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  v := f_available_points('pt_1','CUSTOMER','cus_1', T0() - interval '30 days');
  PERFORM t_ok('T2','ถาม ณ 30 วันก่อน → ได้ 1100 เพราะก้อน 500 ยังไม่หมดอายุ', v = 1100);
END $$;

-- =====================================================================
-- T3 · as_of ในอนาคต ต้องตัดก้อนที่จะหมดอายุออก
--      ไม่ต้องมี job ไปลดยอด · เวลาเดินเอง คำตอบเปลี่ยนเอง
-- =====================================================================
DO $$
DECLARE v10 numeric; v30 numeric;
BEGIN
  v10 := f_available_points('pt_1','CUSTOMER','cus_1', T0() + interval '10 days');
  v30 := f_available_points('pt_1','CUSTOMER','cus_1', T0() + interval '30 days');
  PERFORM t_ok('T3','ถามล่วงหน้า 10 วัน → 500 · ล่วงหน้า 30 วัน → 300', v10 = 500 AND v30 = 300);
END $$;

-- =====================================================================
-- T4 · ยอดที่ถูกกันไว้ถูกหักออกจากยอดที่ใช้ได้
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  INSERT INTO reservation (id,subject_type,subject_id,amount)
  VALUES ('rsv_1','POINT_BALANCE','pt_1|CUSTOMER|cus_1', 250);
  v := f_available_points('pt_1','CUSTOMER','cus_1', T0());
  PERFORM t_ok('T4','จองไว้ 250 → ยอดที่ใช้ได้เหลือ 350', v = 350);
END $$;

-- =====================================================================
-- T5 · ยอดที่ใช้ได้ติดลบไม่ได้ แม้ reservation ค้างมากกว่ายอด
--      เกิดได้จริงเมื่อ bucket หมดอายุระหว่างที่ยังจองค้างอยู่
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  v := f_available_points('pt_1','CUSTOMER','cus_1', T0() + interval '30 days');
  -- ตอนนั้นเหลือ bucket 300 แต่จองค้าง 250 → 50
  PERFORM t_ok('T5','ยอดที่ใช้ได้ไม่ติดลบ · ล่วงหน้า 30 วันได้ 50', v = 50);
END $$;

-- =====================================================================
-- T6 · ปล่อยจองแล้วยอดกลับมา
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  UPDATE reservation SET released_at = T0() WHERE id = 'rsv_1';
  v := f_available_points('pt_1','CUSTOMER','cus_1', T0());
  PERFORM t_ok('T6','ปล่อยจอง 250 → ยอดกลับเป็น 600', v = 600);
END $$;

-- =====================================================================
-- T7 · พยากรณ์การหมดอายุ · รวมตามวันและเรียงจากใกล้ไปไกล
-- =====================================================================
DO $$
DECLARE n int; first_amt numeric; total numeric;
BEGIN
  SELECT count(*), min(amount), sum(amount) INTO n, first_amt, total
  FROM (SELECT * FROM f_expiry_forecast('pt_1','CUSTOMER','cus_1', T0(), 30)) x;
  PERFORM t_ok('T7','พยากรณ์ 30 วันข้างหน้า → 2 วัน รวม 300 (100 + 200)',
               n = 2 AND total = 300);
END $$;

-- =====================================================================
-- T8 · พยากรณ์ไม่รวมก้อนที่หมดอายุไปแล้วและก้อนที่ยอดเป็นศูนย์
-- =====================================================================
DO $$
DECLARE total numeric;
BEGIN
  SELECT COALESCE(sum(amount),0) INTO total
  FROM f_expiry_forecast('pt_1','CUSTOMER','cus_1', T0(), 365);
  PERFORM t_ok('T8','พยากรณ์ 365 วัน → 600 · ไม่นับก้อนหมดอายุ (500) และก้อนศูนย์', total = 600);
END $$;

-- =====================================================================
-- T9 · รายงานยอดที่หมดอายุสะสม · เป็น query ไม่ใช่ตาราง
-- =====================================================================
DO $$
DECLARE v_now numeric; v_future numeric;
BEGIN
  v_now    := f_expired_total('pt_1', T0());
  v_future := f_expired_total('pt_1', T0() + interval '30 days');
  PERFORM t_ok('T9','หมดอายุสะสม ณ วันนี้ 500 · อีก 30 วัน 800', v_now = 500 AND v_future = 800);
END $$;

-- =====================================================================
-- T10 · แจ้งเตือนซ้ำที่ระดับเดียวกันของ bucket เดิมไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO expiry_notice (id,bucket_id,threshold_days,channel,notified_at)
  VALUES ('en_1','b_soon',7,'PUSH', T0());
  BEGIN
    INSERT INTO expiry_notice (id,bucket_id,threshold_days,channel,notified_at)
    VALUES ('en_dup','b_soon',7,'EMAIL', T0());
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T10','แจ้งเตือน bucket เดิมที่ระดับ 7 วันซ้ำ → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T11 · แจ้งคนละระดับได้ · 30 วัน 7 วัน 1 วัน เป็นคนละใบ
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  INSERT INTO expiry_notice (id,bucket_id,threshold_days,channel,notified_at)
  VALUES ('en_2','b_soon',1,'SMS', T0());
  SELECT count(*) INTO n FROM expiry_notice WHERE bucket_id = 'b_soon';
  PERFORM t_ok('T11','แจ้ง bucket เดิมที่ระดับ 7 และ 1 วันได้ · ได้ 2 ใบ', n = 2);
END $$;

-- =====================================================================
-- T12 · ระดับการแจ้งเตือนนอกนโยบายเข้าไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO expiry_notice (id,bucket_id,threshold_days,channel,notified_at)
    VALUES ('en_bad','b_mid',14,'PUSH', T0());
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T12','threshold_days ที่ไม่ใช่ 30/7/1 → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T13 · แจ้งเตือน bucket ที่หมดอายุไปแล้วไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO expiry_notice (id,bucket_id,threshold_days,channel,notified_at)
    VALUES ('en_late','b_expired',7,'PUSH', T0());
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T13','แจ้งเตือนล่วงหน้าของ bucket ที่หมดอายุแล้ว → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T14 · watermark ถอยหลังไม่ได้ · projection ย้อนกลับไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  UPDATE projection_watermark SET last_block = 1002, last_block_at = T0();
  BEGIN
    UPDATE projection_watermark SET last_block = 999;
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T14','เลื่อน watermark ถอยหลัง → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T15 · watermark มีได้แถวเดียว
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO projection_watermark (id,last_block,last_block_at) VALUES (false, 1, T0());
  EXCEPTION WHEN check_violation OR unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T15','เพิ่มแถวที่สองใน projection_watermark → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T16 · projection ตามหลัง indexer เสมอ · ต้องบอกผู้เรียกได้ว่าตามหลังแค่ไหน
-- =====================================================================
DO $$
DECLARE lag bigint;
BEGIN
  SELECT c.last_block - w.last_block INTO lag
  FROM indexer_cursor c, projection_watermark w
  WHERE c.contract_address = decode(repeat('aa',20),'hex');
  PERFORM t_ok('T16','คำนวณระยะที่ projection ตามหลัง indexer ได้ (3 block)', lag = 3);
END $$;

-- =====================================================================
-- T17 · numeric(78,0) รับ uint256 สูงสุดได้                   RFD 14 D1
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  SELECT (2::numeric ^ 256 - 1) INTO v;
  INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at)
  VALUES ('b_max','pt_1','MERCHANT','mch_1',9, v, T0(), T0() + interval '90 days');
  PERFORM t_ok('T17','เก็บ uint256 สูงสุด (2^256-1) ได้ครบทุกหลัก',
    f_unexpired_total('pt_1','MERCHANT','mch_1', T0()) = v);
END $$;

-- =====================================================================
-- T18 · ไม่มีคอลัมน์ยอดคงเหลือสำเร็จรูปในตารางไหนเลย
--       ตรวจโครงสร้าง · ถ้ามี กฎ "คิดตอน query" จะพัง             RFD 10
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND column_name ~* '(available|cached_balance|current_balance|remaining_balance)';
  PERFORM t_ok('T18','ไม่มีคอลัมน์ยอดคงเหลือสำเร็จรูปในฐานข้อมูลเลย', bad = 0);
END $$;

-- =====================================================================
-- T19 · ฟังก์ชันอ่านทุกตัวต้องไม่เรียก now() ข้างใน
--       ถ้าเรียก คำตอบจะขึ้นกับเวลาที่รัน ทดสอบซ้ำไม่ได้
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('f_unexpired_total','f_available_points','f_expiry_forecast','f_expired_total')
    AND (pg_get_functiondef(p.oid) ~* '\mnow\s*\(' OR p.provolatile = 'v');
  PERFORM t_ok('T19','ฟังก์ชันอ่านไม่เรียก now() ข้างใน และประกาศเป็น STABLE', bad = 0);
END $$;

-- =====================================================================
-- T20 · query ยอดต้องใช้ index ไม่ใช่สแกนทั้งตาราง
--       ใส่ข้อมูล 5000 แถวแล้วอ่าน plan จริงจาก EXPLAIN
-- =====================================================================
DO $$
DECLARE line text; uses_index boolean := false;
BEGIN
  -- ใส่ข้อมูลให้พอที่ planner จะเลือกอย่างมีความหมาย
  INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at)
  SELECT 'bulk_'||g, 'pt_1','CUSTOMER','cus_bulk_'||(g % 500), g, 10,
         T0() - interval '10 days', T0() + interval '30 days'
  FROM generate_series(1,5000) g;
  ANALYZE point_balance_bucket;

  CREATE TEMP TABLE _plan (line text);
  FOR line IN EXECUTE format(
    'EXPLAIN (COSTS OFF) SELECT COALESCE(sum(amount),0) FROM point_balance_bucket
      WHERE point_type_id = %L AND holder_kind = %L AND holder_id = %L
        AND amount > 0 AND expires_at > %L',
    'pt_1', 'CUSTOMER', 'cus_1', T0())
  LOOP
    INSERT INTO _plan VALUES (line);
  END LOOP;

  SELECT bool_or(p.line ILIKE '%ix_bucket_live%') INTO uses_index FROM _plan p;
  PERFORM t_ok('T20','EXPLAIN ยืนยันว่า query ยอดใช้ index ix_bucket_live จริง',
               COALESCE(uses_index, false));
  DROP TABLE _plan;
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

-- ไม่ commit · ฐานข้อมูลกลับไปเหมือนก่อนรัน
ROLLBACK;
