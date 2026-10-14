-- =====================================================================
-- FEAT-14 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat14 -f tests/acceptance.sql
-- ทุกแถวต้องขึ้น PASS · แถวเดียวที่ FAIL = schema ไม่ให้สิ่งที่ RFD สัญญาไว้
--
-- หัวใจของไฟล์นี้
--   T2-T6     L8 ข้อแรก · indexer เดียว · lease กัน process ที่ค้าง
--   T7-T10    RFD 5 · reorg ตรวจด้วย block_hash · สายโซ่ที่ขาดเก็บไม่ได้
--   T11-T12   L8 ข้อสอง · cursor ขยับใน transaction เดียวกับ event
--   T20-T23   RFD 6 §3.2 · ลบ projection แล้ว replay ต้องได้ค่าเดิมเป๊ะ
--             ข้อนี้ทุก pack ก่อนหน้าอ้างถึงแต่ไม่มีใครพิสูจน์
--             ที่นี่พิสูจน์ด้วยการทำจริง ไม่ใช่ด้วยการอธิบาย
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

BEGIN;

CREATE TEMP TABLE result (id text, what text, verdict text);

CREATE OR REPLACE FUNCTION t_ok(p_id text, p_what text, p_pass boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO result VALUES (p_id, p_what, CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END) $$;

-- hash ของสายหลัก และของสายที่แยกออกไป (ใช้ทดสอบ reorg)
CREATE OR REPLACE FUNCTION bh(n bigint) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to('block-' || n, 'UTF8')) $$;
CREATE OR REPLACE FUNCTION fh(n bigint) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to('fork-' || n, 'UTF8')) $$;
CREATE OR REPLACE FUNCTION th(s text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to('tx-' || s, 'UTF8')) $$;

-- topic0 · ของจริงมาจาก keccak256 ของ signature ใน ABI
-- ที่นี่ใช้ค่าแทนที่คงที่ เพราะ pack นี้ทดสอบ schema ไม่ได้ทดสอบการถอดรหัส
CREATE OR REPLACE FUNCTION topic(s text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to('topic-' || s, 'UTF8')) $$;

-- อ่านบล็อกหนึ่งบล็อกบนสายหลัก พร้อมขยับ cursor (L8)
CREATE OR REPLACE FUNCTION read_block(n bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO raw_block (block_number, block_hash, parent_hash, timestamp, tx_count)
  VALUES (n, bh(n), bh(n - 1), timestamptz '2026-01-01 00:00:00' + (n * interval '12 seconds'), 1);
  UPDATE indexer_cursor SET last_block = n, last_block_hash = bh(n), updated_at = now()
   WHERE id = 'main';
END $$;

CREATE OR REPLACE FUNCTION add_event(
  p_id text, p_block bigint, p_log int, p_name chain_event_name, p_args jsonb
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO chain_event (id, block_number, block_hash, tx_hash, log_index, address,
                          topic0, data, block_timestamp, event_name, args)
  VALUES (p_id, p_block, (SELECT block_hash FROM raw_block
                           WHERE block_number = p_block AND orphaned_at IS NULL),
          th(p_id), p_log, decode(repeat('aa',20),'hex'),
          topic(p_name::text), '\x00',
          (SELECT timestamp FROM raw_block
            WHERE block_number = p_block AND orphaned_at IS NULL),
          p_name, p_args);
END $$;

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id,name,status) VALUES ('mch_a','ร้าน','ACTIVE');
INSERT INTO customer (id) VALUES ('cus_1'),('cus_2'),('cus_3');
INSERT INTO point_type (id,merchant_id,name) VALUES ('pt_1','mch_a','แต้มสะสม');
INSERT INTO coupon_type (id,merchant_id,name) VALUES ('ct_1','mch_a','คูปอง 100');

INSERT INTO coupon_code (id,coupon_type_id,code_ref)
SELECT 'cc_'||g, 'ct_1', sha256(convert_to('cc_'||g,'UTF8')) FROM generate_series(1,5) g;

INSERT INTO finality_config (id,depth_blocks,effective_from,note) VALUES
 ('fin_v1', 12, now() - interval '30 days', 'ค่าตั้งต้น · ยังไม่ยืนยันกับทีม chain'),
 ('fin_v2',  6, now() + interval '30 days', 'ลดลงในอนาคตถ้า chain นิ่งพอ');

INSERT INTO indexer_cursor (id,last_block) VALUES ('main', 0);

-- =====================================================================
-- T1 · cursor มีได้แถวเดียว · id ต้องเป็น main
-- =====================================================================
DO $$
BEGIN
  INSERT INTO indexer_cursor (id,last_block) VALUES ('second', 0);
  PERFORM t_ok('T1','cursor แถวที่สอง → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T1','cursor แถวที่สอง → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T2 · L8 · ขยับ cursor โดยไม่มี lease → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE indexer_cursor SET last_block = 1, last_block_hash = bh(1) WHERE id = 'main';
  PERFORM t_ok('T2','L8 · ขยับ cursor โดยไม่มี lease → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T2','L8 · ขยับ cursor โดยไม่มี lease → ถูกปฏิเสธ', true);
END $$;

-- ขอ lease
UPDATE indexer_cursor SET lease_owner = 'indexer-1',
       lease_until = now() + interval '30 seconds' WHERE id = 'main';

-- =====================================================================
-- T3 · lease หมดอายุแล้วขยับ → ถูกปฏิเสธ
-- กัน process ที่ยังไม่ตายแต่หยุดตอบสนอง · advisory lock ดักไม่ได้
-- =====================================================================
DO $$
BEGIN
  UPDATE indexer_cursor SET lease_until = now() - interval '1 second' WHERE id='main';
  UPDATE indexer_cursor SET last_block = 1, last_block_hash = bh(1) WHERE id='main';
  PERFORM t_ok('T3','lease หมดอายุแล้วขยับ cursor → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T3','lease หมดอายุแล้วขยับ cursor → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T4 · เปลี่ยนเจ้าของ lease พร้อมกับขยับ cursor → ถูกปฏิเสธ
-- สองเรื่องนี้ต้องแยกสเตตเมนต์ · ไม่งั้นมีช่องให้แย่ง lease ระหว่างขยับ
-- =====================================================================
DO $$
BEGIN
  UPDATE indexer_cursor SET lease_owner = 'indexer-2',
         lease_until = now() + interval '30 seconds',
         last_block = 1, last_block_hash = bh(1) WHERE id='main';
  PERFORM t_ok('T4','เปลี่ยนเจ้าของ lease พร้อมขยับ cursor → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T4','เปลี่ยนเจ้าของ lease พร้อมขยับ cursor → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T5 · ถือ lease ที่ยังไม่หมดอายุ · ขยับได้
-- =====================================================================
DO $$
DECLARE v bigint;
BEGIN
  PERFORM read_block(1);
  SELECT last_block INTO v FROM indexer_cursor WHERE id='main';
  PERFORM t_ok('T5','ถือ lease อยู่ · ขยับ cursor ได้', v = 1);
END $$;

-- =====================================================================
-- T6 · cursor ถอยหลังนอกเหตุ reorg → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE indexer_cursor SET last_block = 0, last_block_hash = NULL WHERE id='main';
  PERFORM t_ok('T6','cursor ถอยหลังนอกเหตุ reorg → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T6','cursor ถอยหลังนอกเหตุ reorg → ถูกปฏิเสธ', true);
END $$;

-- อ่านต่อถึงบล็อก 20
SELECT read_block(g) FROM generate_series(2,20) g;

-- =====================================================================
-- T7 · RFD 5 · บล็อกที่ parent_hash ไม่ตรงกับบล็อกก่อนหน้า → ถูกปฏิเสธ
-- นี่คือการตรวจ reorg ด้วยการเทียบ hash ไม่ใช่นับความลึก
-- สายโซ่ที่ขาดเก็บลงฐานข้อมูลไม่ได้เลย
-- =====================================================================
DO $$
BEGIN
  INSERT INTO raw_block (block_number, block_hash, parent_hash, timestamp)
  VALUES (21, bh(21), fh(20), now());   -- parent ชี้ไปสายอื่น
  PERFORM t_ok('T7','RFD 5 · parent_hash ไม่ตรง → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T7','RFD 5 · parent_hash ไม่ตรง → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T8 · บล็อกที่ไม่มีบล็อกก่อนหน้าในฐานข้อมูล · ไม่มีอะไรให้เทียบ
-- เริ่มอ่านกลางสายได้ ไม่ต้องอ่านจากบล็อกหนึ่งเสมอ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO raw_block (block_number, block_hash, parent_hash, timestamp)
  VALUES (9000, bh(9000), bh(8999), now());
  PERFORM t_ok('T8','บล็อกที่ไม่มีตัวก่อนหน้า · รับได้ ไม่มีอะไรให้เทียบ', true);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T8','บล็อกที่ไม่มีตัวก่อนหน้า · รับได้ ไม่มีอะไรให้เทียบ', false);
END $$;
DELETE FROM raw_block WHERE block_number = 9000;

-- =====================================================================
-- T9 · block_hash ซ้ำ → ถูกปฏิเสธ · hash คือตัวตนของบล็อก
-- =====================================================================
DO $$
BEGIN
  INSERT INTO raw_block (block_number, block_hash, parent_hash, timestamp)
  VALUES (21, bh(20), bh(20), now());
  PERFORM t_ok('T9','block_hash ซ้ำ → ชน primary key', false);
EXCEPTION WHEN unique_violation OR check_violation THEN
  PERFORM t_ok('T9','block_hash ซ้ำ → ชน primary key', true);
END $$;

-- =====================================================================
-- T10 · บล็อกที่เป็น parent ของตัวเอง → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO raw_block (block_number, block_hash, parent_hash, timestamp)
  VALUES (21, bh(21), bh(21), now());
  PERFORM t_ok('T10','บล็อกที่เป็น parent ของตัวเอง → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T10','บล็อกที่เป็น parent ของตัวเอง → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T11 · L8 ข้อสอง · insert event ที่บล็อกเกิน cursor → ไม่ผ่าน COMMIT
--
-- เขียน event แล้วไม่ขยับ cursor คือสิ่งที่ L8 ห้าม
-- indexer ที่ restart จะอ่านช่วงนั้นใหม่แล้วสถานะสับสน
-- =====================================================================
DO $$
BEGIN
  INSERT INTO raw_block (block_number, block_hash, parent_hash, timestamp)
  VALUES (21, bh(21), bh(20), now());
  PERFORM add_event('ce_ahead', 21, 0, 'UNKNOWN', NULL);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM t_ok('T11','L8 · event ที่บล็อกเกิน cursor → ไม่ผ่าน', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T11','L8 · event ที่บล็อกเกิน cursor → ไม่ผ่าน', true);
END $$;

-- =====================================================================
-- T12 · L8 · insert event พร้อมขยับ cursor ใน transaction เดียว → ผ่าน
-- =====================================================================
DO $$
BEGIN
  PERFORM read_block(21);
  PERFORM add_event('ce_ok', 21, 0, 'UNKNOWN', NULL);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM t_ok('T12','L8 · event พร้อมขยับ cursor ใน tx เดียว → ผ่าน', true);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T12','L8 · event พร้อมขยับ cursor ใน tx เดียว → ผ่าน', false);
END $$;

-- =====================================================================
-- T13 · อ่าน log ช่วงเดิมซ้ำ → ไม่เกิดแถวซ้ำ
-- indexer ที่ restart จะอ่านทับช่วงเดิมเสมอ · ข้อนี้ทำให้ปลอดภัย
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_r1',21,bh(21),th('dup'),5,decode(repeat('aa',20),'hex'),
          topic('x'),'\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_r2',21,bh(21),th('dup'),5,decode(repeat('aa',20),'hex'),
          topic('x'),'\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T13','อ่าน log ช่วงเดิมซ้ำ → ไม่เกิดแถวซ้ำ', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T14 · event ที่รู้จักชนิดต้องมี args · ถอดรหัสไม่ได้แล้วบอกว่ารู้จักไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp,event_name)
  VALUES ('ce_noargs',21,bh(21),th('noargs'),6,decode(repeat('aa',20),'hex'),
          topic('CouponTransfer'),'\x00',now(),'CouponTransfer');
  PERFORM t_ok('T14','event ที่รู้จักชนิดแต่ไม่มี args → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T14','event ที่รู้จักชนิดแต่ไม่มี args → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T15 · chain_event ต้องอ้าง block ที่มีอยู่จริง
-- =====================================================================
DO $$
BEGIN
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_ghost',21,fh(999),th('ghost'),7,decode(repeat('aa',20),'hex'),
          topic('x'),'\x00',now());
  PERFORM t_ok('T15','event ที่อ้าง block ที่ไม่มีอยู่ → ถูกปฏิเสธ', false);
EXCEPTION WHEN foreign_key_violation THEN
  PERFORM t_ok('T15','event ที่อ้าง block ที่ไม่มีอยู่ → ถูกปฏิเสธ', true);
END $$;

-- ---------------------------------------------------------------------
-- ฉากสำหรับการ apply และ replay · event จริงที่มีความหมาย
-- สร้างที่ top level ทั้งหมด เพราะ block ที่คาดว่าจะ raise จะ rollback ฉาก
-- ---------------------------------------------------------------------
SELECT read_block(g) FROM generate_series(22,30) g;

-- บล็อก 22 · คูปองสองใบเข้า cus_1
SELECT add_event('ce_t1', 22, 0, 'CouponTransfer',
  jsonb_build_object('codeRef', encode(sha256(convert_to('cc_1','UTF8')),'hex'),
                     'toKind','CUSTOMER','toId','cus_1'));
SELECT add_event('ce_t2', 22, 1, 'CouponTransfer',
  jsonb_build_object('codeRef', encode(sha256(convert_to('cc_2','UTF8')),'hex'),
                     'toKind','CUSTOMER','toId','cus_1'));

-- บล็อก 23 · point mint เข้า cus_1 แล้วโอนบางส่วนไป cus_2
SELECT add_event('ce_p1', 23, 0, 'PointTransfer',
  jsonb_build_object('pointTypeId','pt_1','toKind','CUSTOMER','toId','cus_1',
                     'amount','1000','fromId',''));
SELECT add_event('ce_p2', 23, 1, 'PointTransfer',
  jsonb_build_object('pointTypeId','pt_1','toKind','CUSTOMER','toId','cus_2',
                     'amount','300','fromKind','CUSTOMER','fromId','cus_1'));

-- บล็อก 24 · คูปองใบแรกย้ายไป cus_2 แล้วถูกใช้
SELECT add_event('ce_t3', 24, 0, 'CouponTransfer',
  jsonb_build_object('codeRef', encode(sha256(convert_to('cc_1','UTF8')),'hex'),
                     'toKind','CUSTOMER','toId','cus_2'));
SELECT add_event('ce_t4', 24, 1, 'CouponRedeemed',
  jsonb_build_object('codeRef', encode(sha256(convert_to('cc_2','UTF8')),'hex')));

-- บล็อก 25 · event ชนิดที่ยังไม่รู้จัก
SELECT add_event('ce_u1', 25, 0, 'UNKNOWN', NULL);

-- =====================================================================
-- T16 · apply ตามลำดับ · ผลลัพธ์ถูกต้องทั้ง coupon และ point
-- =====================================================================
DO $$
DECLARE n int; v_h1 text; v_h2 text; v_b1 numeric; v_b2 numeric; v_st coupon_code_state;
BEGIN
  n := f_apply_pending();
  SELECT holder_id INTO v_h1 FROM coupon_holding WHERE coupon_code_id='cc_1';
  SELECT count(*)::int INTO n FROM chain_event WHERE applied_at IS NOT NULL;
  SELECT amount INTO v_b1 FROM point_balance
   WHERE holder_id='cus_1' AND point_type_id='pt_1';
  SELECT amount INTO v_b2 FROM point_balance
   WHERE holder_id='cus_2' AND point_type_id='pt_1';
  SELECT state INTO v_st FROM coupon_code WHERE id='cc_2';
  SELECT holder_id INTO v_h2 FROM coupon_holding WHERE coupon_code_id='cc_2';
  PERFORM t_ok('T16','apply ครบ · คูปองย้ายถูก · point 700 กับ 300 · ใบที่ใช้แล้วหายจาก holding',
               v_h1 = 'cus_2' AND v_b1 = 700 AND v_b2 = 300
           AND v_st = 'REDEEMED' AND v_h2 IS NULL);
END $$;

-- =====================================================================
-- T17 · apply ซ้ำไม่นับสอง · f_apply_event คืน false ถ้า apply แล้ว
-- =====================================================================
DO $$
DECLARE v boolean; n int; v_b numeric;
BEGIN
  v := f_apply_event('ce_p1');
  n := f_apply_pending();
  SELECT amount INTO v_b FROM point_balance
   WHERE holder_id='cus_1' AND point_type_id='pt_1';
  PERFORM t_ok('T17','apply ซ้ำไม่นับสอง · ยอดยังเป็น 700', v = false AND n = 0 AND v_b = 700);
END $$;

-- =====================================================================
-- T18 · event ชนิดที่ยังไม่รู้จัก · apply แล้วแต่ไม่แตะ projection
-- ไม่ค้างในคิวตลอดไป และไม่ทำให้ projection เพี้ยน
-- =====================================================================
DO $$
DECLARE v timestamptz; n int;
BEGIN
  SELECT applied_at INTO v FROM chain_event WHERE id='ce_u1';
  SELECT count(*)::int INTO n FROM coupon_holding;
  PERFORM t_ok('T18','event ชนิดที่ไม่รู้จัก · apply แล้วแต่ไม่แตะ projection',
               v IS NOT NULL AND n = 1);
END $$;

-- =====================================================================
-- T19 · event ที่อ้าง code_ref ที่ไม่มีในระบบ → ถูกปฏิเสธตอน apply
-- ไม่เงียบๆ ข้ามไป · ถ้า chain พูดถึงของที่เราไม่รู้จัก ต้องรู้
-- =====================================================================
DO $$
BEGIN
  PERFORM add_event('ce_bad', 25, 1, 'CouponTransfer',
    jsonb_build_object('codeRef', encode(sha256(convert_to('ไม่มีจริง','UTF8')),'hex'),
                       'toKind','CUSTOMER','toId','cus_3'));
  PERFORM f_apply_event('ce_bad');
  PERFORM t_ok('T19','event ที่อ้าง code_ref ที่ไม่มี → ถูกปฏิเสธตอน apply', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T19','event ที่อ้าง code_ref ที่ไม่มี → ถูกปฏิเสธตอน apply', true);
END $$;

-- =====================================================================
-- =====  T20 ถึง T23 · RFD 6 §3.2 · พิสูจน์ด้วยการทำจริง  ==============
--
-- ลบ projection ทั้งหมด แล้ว replay chain_event ใหม่
-- ต้องได้ค่าเดิมเป๊ะ · เทียบทุกคอลัมน์ทุกแถว ไม่ใช่เทียบแค่จำนวน
-- =====================================================================
CREATE TEMP TABLE snap_holding AS SELECT * FROM coupon_holding;
CREATE TEMP TABLE snap_balance AS SELECT * FROM point_balance;
CREATE TEMP TABLE snap_code    AS SELECT id, state FROM coupon_code;
CREATE TEMP TABLE snap_meta    AS
  SELECT count(*) AS applied FROM chain_event WHERE applied_at IS NOT NULL;

SELECT f_replay_projections();

-- =====================================================================
-- T20 · RFD 6 §3.2 · coupon_holding เหมือนเดิมเป๊ะทุกคอลัมน์
-- =====================================================================
DO $$
DECLARE v_diff int; v_n int;
BEGIN
  SELECT count(*)::int INTO v_diff FROM (
      (SELECT * FROM coupon_holding EXCEPT SELECT * FROM snap_holding)
      UNION ALL
      (SELECT * FROM snap_holding EXCEPT SELECT * FROM coupon_holding)) d;
  SELECT count(*)::int INTO v_n FROM snap_holding;
  PERFORM t_ok('T20','RFD 6 · ลบแล้ว replay · coupon_holding เหมือนเดิมเป๊ะ',
               v_diff = 0 AND v_n > 0);
END $$;

-- =====================================================================
-- T21 · RFD 6 §3.2 · point_balance เหมือนเดิมเป๊ะทุกคอลัมน์
-- =====================================================================
DO $$
DECLARE v_diff int; v_n int;
BEGIN
  SELECT count(*)::int INTO v_diff FROM (
      (SELECT * FROM point_balance EXCEPT SELECT * FROM snap_balance)
      UNION ALL
      (SELECT * FROM snap_balance EXCEPT SELECT * FROM point_balance)) d;
  SELECT count(*)::int INTO v_n FROM snap_balance;
  PERFORM t_ok('T21','RFD 6 · ลบแล้ว replay · point_balance เหมือนเดิมเป๊ะ',
               v_diff = 0 AND v_n = 2);
END $$;

-- =====================================================================
-- T22 · state ของ coupon_code ก็เป็น projection · ต้องเหมือนเดิมด้วย
-- ข้อนี้พลาดได้ง่าย เพราะตารางนี้ไม่ได้ชื่อว่าเป็น projection
-- แต่ CouponRedeemed เขียนทับมัน จึงต้องย้อนได้เหมือนกัน
-- =====================================================================
DO $$
DECLARE v_diff int;
BEGIN
  SELECT count(*)::int INTO v_diff FROM (
      (SELECT id, state FROM coupon_code EXCEPT SELECT id, state FROM snap_code)
      UNION ALL
      (SELECT id, state FROM snap_code EXCEPT SELECT id, state FROM coupon_code)) d;
  PERFORM t_ok('T22','RFD 6 · state ของ coupon_code เหมือนเดิมเป๊ะ', v_diff = 0);
END $$;

-- =====================================================================
-- T23 · projection ไม่มีคอลัมน์ที่ค่ามาจากเวลาที่ apply
--
-- ถ้ามี now() ในตาราง projection การ replay จะได้ค่าต่างทันที
-- as_of_time ต้องมาจาก block_timestamp เท่านั้น · ข้อนี้ตรวจว่ามันเป็นเช่นนั้น
-- =====================================================================
DO $$
DECLARE v_bad int; v_applied int; v_snap int;
BEGIN
  SELECT count(*)::int INTO v_bad FROM coupon_holding h
    JOIN chain_event e ON e.block_number = h.as_of_block AND e.orphaned_at IS NULL
   WHERE h.as_of_time <> e.block_timestamp;
  SELECT count(*)::int INTO v_applied FROM chain_event WHERE applied_at IS NOT NULL;
  SELECT applied INTO v_snap FROM snap_meta;
  PERFORM t_ok('T23','as_of_time มาจาก block ไม่ใช่เวลาที่ apply · จำนวน event เท่าเดิม',
               v_bad = 0 AND v_applied = v_snap);
END $$;

-- ---------------------------------------------------------------------
-- อ่านต่อให้ tip ไปไกลพอที่ event ชุดแรกจะกลายเป็น final
--
-- N = 12 · tip 45 → บล็อก 33 ลงมาถือว่า final
-- event ที่บล็อก 22 ถึง 25 จึง final และ orphan ไม่ได้อีก (T27)
-- ถ้าไม่อ่านไปไกลพอ T27 กับ T29 จะไม่ได้ทดสอบสิ่งที่มันอ้าง
-- ซึ่งเป็นสิ่งที่พลาดไปรอบแรก และกว่าจะเห็นก็ไล่ย้อนสามข้อ
-- ---------------------------------------------------------------------
SELECT read_block(g) FROM generate_series(31,45) g;

-- =====================================================================
-- T24 · reorg ตื้นกว่า N และไม่กิน event ที่ final → ROLLED_BACK
-- บล็อก 45 หลุดใบเดียว · event ในนั้นถูก orphan แล้ว replay ใหม่
-- =====================================================================
SELECT add_event('ce_t5', 45, 0, 'CouponTransfer',
  jsonb_build_object('codeRef', encode(sha256(convert_to('cc_3','UTF8')),'hex'),
                     'toKind','CUSTOMER','toId','cus_3'));
SELECT f_apply_pending();

DO $$
DECLARE v_id text; v_out reorg_outcome; v_cur bigint; v_n int; v_h int; v_depth int;
BEGIN
  v_id := f_handle_reorg(45, 'indexer-1');
  SELECT outcome, depth INTO v_out, v_depth FROM reorg_log WHERE id = v_id;
  SELECT last_block INTO v_cur FROM indexer_cursor WHERE id='main';
  SELECT count(*)::int INTO v_n FROM chain_event
   WHERE block_number >= 45 AND orphaned_at IS NOT NULL;
  SELECT count(*)::int INTO v_h FROM coupon_holding WHERE coupon_code_id='cc_3';
  PERFORM t_ok('T24','reorg ลึก 1 → ROLLED_BACK · cursor ถอยไป 44 · event หลุด · projection ย้อน',
               v_out = 'ROLLED_BACK' AND v_depth = 1 AND v_cur = 44
           AND v_n = 1 AND v_h = 0);
END $$;

-- =====================================================================
-- T25 · projection หลัง reorg ยังเหมือน snapshot เดิม
-- เพราะ event ที่หลุดไม่เคยมีผลถาวร
-- =====================================================================
DO $$
DECLARE v_diff int;
BEGIN
  SELECT count(*)::int INTO v_diff FROM (
      (SELECT * FROM coupon_holding EXCEPT SELECT * FROM snap_holding)
      UNION ALL
      (SELECT * FROM snap_holding EXCEPT SELECT * FROM coupon_holding)) d;
  PERFORM t_ok('T25','หลัง reorg · projection กลับไปเหมือน snapshot ก่อนบล็อกที่หลุด',
               v_diff = 0);
END $$;

-- =====================================================================
-- T26 · บล็อกใหม่บนสายที่ชนะ เขียนได้ ทั้งที่ความสูงเดิมมีบล็อกอยู่แล้ว
--
-- ข้อนี้เป็นไปได้เพราะ primary key ของ raw_block เป็น block_hash
-- ไม่ใช่ block_number · ความสูงเดียวกันมีได้สองใบ ใบหนึ่ง orphan
-- =====================================================================
DO $$
DECLARE v bytea; n int;
BEGIN
  INSERT INTO raw_block (block_hash, block_number, parent_hash, timestamp)
  VALUES (fh(45), 45, bh(44), now());
  UPDATE indexer_cursor SET last_block = 45, last_block_hash = fh(45) WHERE id='main';
  SELECT last_block_hash INTO v FROM indexer_cursor WHERE id='main';
  SELECT count(*)::int INTO n FROM raw_block WHERE block_number = 45;
  PERFORM t_ok('T26','สายใหม่เขียนได้ · ความสูง 45 มีสองใบ · tip ชี้ใบใหม่',
               v = fh(45) AND n = 2);
EXCEPTION WHEN check_violation OR unique_violation THEN
  PERFORM t_ok('T26','สายใหม่เขียนได้ · ความสูง 45 มีสองใบ · tip ชี้ใบใหม่', false);
END $$;

-- =====================================================================
-- T27 · event ที่ final แล้ว orphan ไม่ได้
--
-- tip 45 · N = 12 → บล็อก 33 ลงมา final · ce_t1 อยู่บล็อก 22 จึง final
-- ถ้า event ที่บอกลูกค้าว่าเสร็จแล้วยังหลุดได้ ค่า N ก็ไม่มีความหมาย
-- =====================================================================
DO $$
DECLARE n int; v_fin timestamptz;
BEGIN
  n := f_mark_finalized();
  SELECT finalized_at INTO v_fin FROM chain_event WHERE id='ce_t1';
  IF v_fin IS NULL THEN
    PERFORM t_ok('T27','event ที่ final แล้ว orphan ไม่ได้', false);
    RETURN;
  END IF;
  UPDATE chain_event SET applied_at = NULL, orphaned_at = now() WHERE id='ce_t1';
  PERFORM t_ok('T27','event ที่ final แล้ว orphan ไม่ได้', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T27','event ที่ final แล้ว orphan ไม่ได้', true);
END $$;

-- =====================================================================
-- T28 · final เฉพาะบล็อกที่ลึกกว่า N เท่านั้น
-- tip 45 · N = 12 → 33 ลงมา final · ที่ลึกน้อยกว่านั้นยังไม่ final
-- =====================================================================
DO $$
DECLARE v_depth int; v_max bigint; v_min_unfinal bigint; v_tip bigint;
BEGIN
  PERFORM f_mark_finalized();
  v_depth := f_finality_depth(now());
  SELECT last_block INTO v_tip FROM indexer_cursor WHERE id='main';
  SELECT max(block_number) INTO v_max FROM chain_event
   WHERE finalized_at IS NOT NULL AND orphaned_at IS NULL;
  SELECT min(block_number) INTO v_min_unfinal FROM chain_event
   WHERE finalized_at IS NULL AND orphaned_at IS NULL AND applied_at IS NOT NULL;
  PERFORM t_ok('T28','final เฉพาะบล็อกที่ลึกกว่า N · tip 45 · N 12 → ถึง 33',
               v_depth = 12 AND v_tip = 45 AND v_max <= v_tip - v_depth
           AND (v_min_unfinal IS NULL OR v_min_unfinal > v_tip - v_depth));
END $$;

-- =====================================================================
-- T29 · reorg ที่กินบล็อกซึ่งมี event final อยู่ → MANUAL_REVIEW
-- ไม่แตะอะไรเลย · ไม่ orphan ไม่ถอย cursor · ปล่อยให้คนตัดสิน
-- =====================================================================
DO $$
DECLARE v_id text; v_out reorg_outcome; v_cur bigint; v_cur2 bigint; v_orph int; v_note text;
BEGIN
  SELECT last_block INTO v_cur FROM indexer_cursor WHERE id='main';
  v_id := f_handle_reorg(22, 'indexer-1');
  SELECT outcome, note INTO v_out, v_note FROM reorg_log WHERE id = v_id;
  SELECT count(*)::int INTO v_orph FROM chain_event
   WHERE block_number >= 22 AND block_number <= 30 AND orphaned_at IS NOT NULL;
  SELECT last_block INTO v_cur2 FROM indexer_cursor WHERE id='main';
  PERFORM t_ok('T29','reorg ที่กิน event final → MANUAL_REVIEW · ไม่แตะอะไรเลย',
               v_out = 'MANUAL_REVIEW' AND v_orph = 0 AND v_cur2 = v_cur
           AND v_note IS NOT NULL);
END $$;

-- =====================================================================
-- T30 · outcome ที่ไม่ตรงกับความลึกจริง → ถูกปฏิเสธ
-- เลือกเองไม่ได้ · แบบเดียวกับ reversal ใน FEAT-12
-- =====================================================================
DO $$
BEGIN
  INSERT INTO reorg_log (id,fork_block,old_tip,depth,finality_depth,
                         orphaned_events,outcome)
  VALUES ('rg_bad',10,40,31,12,0,'ROLLED_BACK');
  PERFORM t_ok('T30','reorg ลึกเกิน N แต่อ้าง ROLLED_BACK → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T30','reorg ลึกเกิน N แต่อ้าง ROLLED_BACK → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T31 · depth ที่ไม่ตรงกับ old_tip ลบ fork_block บวกหนึ่ง → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO reorg_log (id,fork_block,old_tip,depth,finality_depth,
                         orphaned_events,outcome)
  VALUES ('rg_bad2',30,32,99,12,0,'ROLLED_BACK');
  PERFORM t_ok('T31','depth ไม่ตรงกับช่วงบล็อก → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T31','depth ไม่ตรงกับช่วงบล็อก → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T32 · f_finality_depth ตอบตามเวลาที่ถาม
-- เปลี่ยนค่า N วันนี้ ไม่ทำให้อดีตเปลี่ยน
-- =====================================================================
DO $$
DECLARE v_now int; v_future int;
BEGIN
  v_now    := f_finality_depth(now());
  v_future := f_finality_depth(now() + interval '60 days');
  PERFORM t_ok('T32','N อิงเวลา · วันนี้ 12 · อนาคต 6', v_now = 12 AND v_future = 6);
END $$;

-- =====================================================================
-- T33 · orphan แล้ว applied ไม่ได้ · ต้องย้อน projection ก่อน
-- =====================================================================
DO $$
BEGIN
  UPDATE chain_event SET applied_at = now()
   WHERE orphaned_at IS NOT NULL AND id = 'ce_t5';
  PERFORM t_ok('T33','event ที่ orphan แล้ว ทำเครื่องหมาย applied ไม่ได้', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T33','event ที่ orphan แล้ว ทำเครื่องหมาย applied ไม่ได้', true);
END $$;

-- =====================================================================
-- T34 · PointTransfer ที่จ่ายจากบัญชีที่ไม่มียอด → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  PERFORM add_event('ce_nobal', 45, 5, 'PointTransfer',
    jsonb_build_object('pointTypeId','pt_1','toKind','CUSTOMER','toId','cus_1',
                       'amount','50','fromKind','CUSTOMER','fromId','cus_3'));
  PERFORM f_apply_event('ce_nobal');
  PERFORM t_ok('T34','จ่าย point จากบัญชีที่ไม่มียอด → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T34','จ่าย point จากบัญชีที่ไม่มียอด → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T35 · ยอด point ติดลบ → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  PERFORM add_event('ce_neg', 45, 6, 'PointTransfer',
    jsonb_build_object('pointTypeId','pt_1','toKind','CUSTOMER','toId','cus_3',
                       'amount','99999','fromKind','CUSTOMER','fromId','cus_2'));
  PERFORM f_apply_event('ce_neg');
  PERFORM t_ok('T35','จ่าย point เกินยอดที่มี → ยอดติดลบ ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T35','จ่าย point เกินยอดที่มี → ยอดติดลบ ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T36 · ปิดท้าย · ไม่มี event ที่บล็อกเกิน cursor และสายโซ่ไม่ขาด
-- =====================================================================
DO $$
DECLARE v_ahead int; v_broken int; v_cur bigint;
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT last_block INTO v_cur FROM indexer_cursor WHERE id='main';
  SELECT count(*)::int INTO v_ahead FROM chain_event
   WHERE orphaned_at IS NULL AND block_number > v_cur;
  -- ทุกบล็อกบนสายหลักที่มีตัวก่อนหน้า ต้องชี้ไปที่ตัวก่อนหน้าถูก
  SELECT count(*)::int INTO v_broken FROM raw_block b
    JOIN raw_block p ON p.block_number = b.block_number - 1 AND p.orphaned_at IS NULL
   WHERE b.orphaned_at IS NULL AND b.parent_hash <> p.block_hash;
  PERFORM t_ok('T36','ปิดท้าย · ไม่มี event เกิน cursor · สายโซ่บล็อกไม่ขาด',
               v_ahead = 0 AND v_broken = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

ROLLBACK;
