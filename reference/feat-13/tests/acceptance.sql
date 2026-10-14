-- =====================================================================
-- FEAT-13 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat13 -f tests/acceptance.sql
-- ทุกแถวต้องขึ้น PASS · แถวเดียวที่ FAIL = schema ไม่ให้สิ่งที่ RFD สัญญาไว้
--
-- หัวใจของไฟล์นี้
--   T5-T10    ประวัติต้องครบและต่อเนื่อง · API ที่เล่าประวัติต้องเล่าได้ครบ
--   T11-T13   status ไม่ monotonic · reorg มีจริง · client ต้องใช้ seq
--   T20-T24   ส่ง event ของงานเดียวกันเรียงตามลำดับ
--   T28-T30   Group E · ตารางที่ replay ไม่ได้ และทำไมถึงไม่ได้
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

BEGIN;

CREATE TEMP TABLE result (id text, what text, verdict text);

CREATE OR REPLACE FUNCTION t_ok(p_id text, p_what text, p_pass boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO result VALUES (p_id, p_what, CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END) $$;

-- ---------------------------------------------------------------------
-- บังคับให้ constraint trigger ที่ deferred ตรวจเดี๋ยวนี้
--
-- สองข้อที่ต้องรู้ และทั้งสองข้อทำให้เสียเวลาไปรอบหนึ่ง
--
--   1 SET CONSTRAINTS ALL IMMEDIATE ไม่ใช่การตรวจครั้งเดียว
--     มันเปลี่ยนโหมดไปจนจบ transaction · ไม่ตั้งกลับเป็น DEFERRED
--     ทุกการเขียนถัดไปจะถูกตรวจทีละสเตตเมนต์ ซึ่งผิดความหมายของกฎ
--     ที่ออกแบบให้ตรวจเป็นชุดตอน COMMIT
--
--   2 เอาสองสเตตเมนต์นี้ไปใส่ในฟังก์ชันแล้วเรียกจาก DO block ไม่ได้
--     จะได้ stack depth limit exceeded · จึงเขียนตรงๆ ใน block
--
-- ถ้า IMMEDIATE ระเบิด บรรทัดถัดไปไม่ได้รัน แต่ subtransaction ของ
-- DO block ที่จับ exception จะ rollback โหมดกลับให้เอง (ตรวจแล้วว่าจริง)
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- helper · เปลี่ยนสถานะ operation พร้อมเขียน event ให้ครบ
-- นี่คือวิธีเดียวที่ควรเปลี่ยนสถานะ · ที่อื่นเรียกตัวนี้
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION advance(p_op text, p_to operation_status)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_from operation_status; v_seq integer;
BEGIN
  SELECT status INTO v_from FROM operation WHERE id = p_op;
  SELECT coalesce(max(seq), 0) + 1 INTO v_seq FROM operation_event WHERE operation_id = p_op;

  UPDATE operation SET status = p_to WHERE id = p_op;
  INSERT INTO operation_event (id, operation_id, seq, from_status, to_status)
  VALUES ('oev_' || p_op || '_' || v_seq, p_op, v_seq, v_from, p_to);
  RETURN v_seq;
END $$;

-- สร้าง operation ใหม่พร้อม event แถวแรก
CREATE OR REPLACE FUNCTION mk_op(p_op text, p_kind operation_kind DEFAULT 'LISTING_CREATE')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO operation (id, actor_scope, kind, status, payload)
  VALUES (p_op, 'merchant:mch_a', p_kind, 'PENDING', '{}');
  INSERT INTO operation_event (id, operation_id, seq, from_status, to_status)
  VALUES ('oev_' || p_op || '_1', p_op, 1, NULL, 'PENDING');
END $$;

-- สร้างงานส่ง webhook
CREATE OR REPLACE FUNCTION mk_delivery(
  p_id text, p_ep text, p_op text, p_event_seq int, p_dseq int, p_type text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO webhook_delivery (id, endpoint_id, operation_id, event_seq, delivery_seq,
                                event_type, payload, signature, signed_at)
  VALUES (p_id, p_ep, p_op, p_event_seq, p_dseq, p_type,
          jsonb_build_object('operationId', p_op, 'eventSeq', p_event_seq),
          'sha256=' || md5(p_id), now());
END $$;

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id, name, status) VALUES ('mch_a', 'ร้าน', 'ACTIVE');

INSERT INTO webhook_endpoint (id, merchant_id, url, secret_ref, event_types) VALUES
 ('ep_1', 'mch_a', 'https://shop.example.com/hooks', 'kms://webhook/mch_a/v1',
  ARRAY['operation.submitted','operation.finalized','operation.reverted']),
 ('ep_2', 'mch_a', 'https://backup.example.com/hooks', 'kms://webhook/mch_a/v2',
  ARRAY['operation.finalized']);

SELECT mk_op('op_a');
SELECT mk_op('op_b');
SELECT mk_op('op_c');
SELECT mk_op('op_d');
SELECT mk_op('op_e');
SELECT mk_op('op_f');
SELECT mk_op('op_g');
SELECT mk_op('op_reorg');

-- =====================================================================
-- T1 · operation ใหม่ต้องมี event แถวแรกที่ from_status เป็น NULL
-- =====================================================================
DO $$
DECLARE v_from operation_status; v_to operation_status; v_n int;
BEGIN
  SELECT from_status, to_status INTO v_from, v_to
    FROM operation_event WHERE operation_id='op_a' AND seq=1;
  SELECT count(*) INTO v_n FROM operation_event WHERE operation_id='op_a';
  PERFORM t_ok('T1','operation ใหม่มี event seq 1 · from_status เป็น NULL',
               v_from IS NULL AND v_to='PENDING' AND v_n=1);
END $$;

-- =====================================================================
-- T2 · event แถวที่สองที่ from_status เป็น NULL → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_event (id,operation_id,seq,from_status,to_status)
  VALUES ('oev_bad1','op_a',2,NULL,'SUBMITTED');
  PERFORM t_ok('T2','event seq 2 ที่ from_status เป็น NULL → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T2','event seq 2 ที่ from_status เป็น NULL → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T3 · event seq 1 ซ้ำ → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_event (id,operation_id,seq,from_status,to_status)
  VALUES ('oev_bad2','op_a',1,NULL,'PENDING');
  PERFORM t_ok('T3','event seq 1 ซ้ำ → ถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation OR check_violation THEN
  PERFORM t_ok('T3','event seq 1 ซ้ำ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T4 · event กระโดดข้าม seq → ถูกปฏิเสธ · ประวัติต้องต่อเนื่อง
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_event (id,operation_id,seq,from_status,to_status)
  VALUES ('oev_bad3','op_a',5,'PENDING','SUBMITTED');
  PERFORM t_ok('T4','event กระโดดจาก seq 1 ไป 5 → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T4','event กระโดดจาก seq 1 ไป 5 → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T5 · from_status ไม่ตรงกับแถวก่อนหน้า → ถูกปฏิเสธ
-- เขียนอะไรก็ได้ลงไปแล้วประวัติจะโกหก
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_event (id,operation_id,seq,from_status,to_status)
  VALUES ('oev_bad4','op_a',2,'CONFIRMED','FINALIZED');
  PERFORM t_ok('T5','from_status ไม่ตรงกับแถวก่อนหน้า → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T5','from_status ไม่ตรงกับแถวก่อนหน้า → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T6 · เปลี่ยนสถานะโดยไม่เขียน event → ไม่ผ่านตอน COMMIT
-- API ที่เล่าประวัติให้ลูกค้าฟัง จะเล่าไม่ครบถ้าไม่มีกฎนี้
-- =====================================================================
DO $$
BEGIN
  UPDATE operation SET status='SUBMITTED' WHERE id='op_b';
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM t_ok('T6','เปลี่ยนสถานะโดยไม่เขียน event → ไม่ผ่าน', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T6','เปลี่ยนสถานะโดยไม่เขียน event → ไม่ผ่าน', true);
END $$;

-- =====================================================================
-- T7 · เขียน event โดยไม่เปลี่ยนสถานะ → ไม่ผ่านตอน COMMIT
-- ประวัติที่เล่าเกินสิ่งที่เกิดขึ้นก็ผิดเหมือนกัน
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_event (id,operation_id,seq,from_status,to_status)
  VALUES ('oev_only','op_c',2,'PENDING','SUBMITTED');
  -- แตะ operation เพื่อให้ deferred trigger ทำงาน
  UPDATE operation SET error_note='แตะเพื่อให้ตรวจ' WHERE id='op_c';
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM t_ok('T7','เขียน event โดยสถานะไม่เปลี่ยน → ไม่ผ่าน', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T7','เขียน event โดยสถานะไม่เปลี่ยน → ไม่ผ่าน', true);
END $$;

-- =====================================================================
-- T8 · เปลี่ยนสถานะพร้อมเขียน event ครบ → ผ่าน
-- =====================================================================
DO $$
DECLARE v_st operation_status; v_last operation_status; v_seq int;
BEGIN
  PERFORM advance('op_a','SUBMITTED');
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT status INTO v_st FROM operation WHERE id='op_a';
  SELECT to_status, seq INTO v_last, v_seq FROM operation_event
   WHERE operation_id='op_a' ORDER BY seq DESC LIMIT 1;
  PERFORM t_ok('T8','เปลี่ยนสถานะพร้อม event ครบ → ผ่าน · seq เดินเป็น 2',
               v_st='SUBMITTED' AND v_last='SUBMITTED' AND v_seq=2);
END $$;

-- =====================================================================
-- T9 · เส้นทางปกติเดินได้ครบ PENDING → SUBMITTED → CONFIRMED → FINALIZED
-- =====================================================================
DO $$
DECLARE v text[]; v_fin timestamptz;
BEGIN
  PERFORM advance('op_d','SUBMITTED');
  PERFORM advance('op_d','CONFIRMED');
  PERFORM advance('op_d','FINALIZED');
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT array_agg(to_status::text ORDER BY seq) INTO v
    FROM operation_event WHERE operation_id='op_d';
  SELECT finalized_at INTO v_fin FROM operation WHERE id='op_d';
  PERFORM t_ok('T9','เส้นทางปกติ 4 ขั้น · finalized_at ถูกเติมให้เอง',
               v = ARRAY['PENDING','SUBMITTED','CONFIRMED','FINALIZED']
           AND v_fin IS NOT NULL);
END $$;

-- =====================================================================
-- T10 · FINALIZED เป็นปลายทาง · ออกไปไหนไม่ได้
-- =====================================================================
DO $$
BEGIN
  PERFORM advance('op_d','SUBMITTED');
  PERFORM t_ok('T10','FINALIZED กลับไป SUBMITTED → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T10','FINALIZED กลับไป SUBMITTED → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T11 · PENDING ข้ามไป FINALIZED ตรงๆ ไม่ได้
-- =====================================================================
DO $$
BEGIN
  PERFORM advance('op_e','FINALIZED');
  PERFORM t_ok('T11','PENDING ข้ามไป FINALIZED → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T11','PENDING ข้ามไป FINALIZED → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T12 · reorg · CONFIRMED ถอยไป ORPHANED ได้ แล้วยิงใหม่เป็น SUBMITTED
-- status จึงไม่ monotonic · นี่คือความจริงของ chain ไม่ใช่บั๊ก
-- =====================================================================
DO $$
DECLARE v text[];
BEGIN
  PERFORM advance('op_reorg','SUBMITTED');
  PERFORM advance('op_reorg','CONFIRMED');
  PERFORM advance('op_reorg','ORPHANED');
  PERFORM advance('op_reorg','SUBMITTED');
  PERFORM advance('op_reorg','CONFIRMED');
  PERFORM advance('op_reorg','FINALIZED');
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT array_agg(to_status::text ORDER BY seq) INTO v
    FROM operation_event WHERE operation_id='op_reorg';
  PERFORM t_ok('T12','reorg · CONFIRMED → ORPHANED → SUBMITTED → จบได้',
    v = ARRAY['PENDING','SUBMITTED','CONFIRMED','ORPHANED','SUBMITTED','CONFIRMED','FINALIZED']);
END $$;

-- =====================================================================
-- T13 · seq เดินหน้าเสมอ แม้ status จะถอย
-- client ต้องเทียบ seq ไม่ใช่เทียบ status
-- =====================================================================
DO $$
DECLARE v_mono boolean;
BEGIN
  SELECT bool_and(seq = rn) INTO v_mono FROM (
    SELECT seq, row_number() OVER (ORDER BY seq) AS rn
      FROM operation_event WHERE operation_id='op_reorg') s;
  PERFORM t_ok('T13','seq เรียง 1..7 ติดกัน แม้ status จะถอยกลางทาง', v_mono);
END $$;

-- =====================================================================
-- T14 · endpoint ที่เป็น http → ถูกปฏิเสธ
-- ลายเซ็นกัน tamper ได้ แต่ไม่กันการอ่าน
-- =====================================================================
DO $$
BEGIN
  INSERT INTO webhook_endpoint (id,merchant_id,url,secret_ref,event_types)
  VALUES ('ep_http','mch_a','http://shop.example.com/h','kms://webhook/x/v1',
          ARRAY['operation.finalized']);
  PERFORM t_ok('T14','endpoint ที่เป็น http → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T14','endpoint ที่เป็น http → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T15 · L6 analogue · เก็บค่าความลับดิบใน secret_ref → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO webhook_endpoint (id,merchant_id,url,secret_ref,event_types)
  VALUES ('ep_plain','mch_a','https://shop.example.com/h',
          'whsec_8f3a9c2e1b7d4f6a0c5e8b2d9f1a3c7e', ARRAY['operation.finalized']);
  PERFORM t_ok('T15','L6 · เก็บ secret ดิบแทน reference → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T15','L6 · เก็บ secret ดิบแทน reference → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T16 · endpoint ที่ไม่ระบุ event_types เลย → ถูกปฏิเสธ
-- รับทุกอย่างโดยไม่ได้เลือก คือการเผลอ ไม่ใช่การตั้งค่า
-- =====================================================================
DO $$
BEGIN
  INSERT INTO webhook_endpoint (id,merchant_id,url,secret_ref,event_types)
  VALUES ('ep_empty','mch_a','https://shop.example.com/h','kms://webhook/x/v1',
          ARRAY[]::text[]);
  PERFORM t_ok('T16','endpoint ที่ไม่ระบุ event_types → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T16','endpoint ที่ไม่ระบุ event_types → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T17 · ส่ง webhook เรื่อง event ที่ไม่มีอยู่ → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  PERFORM mk_delivery('wd_ghost','ep_1','op_a',99,1,'operation.finalized');
  PERFORM t_ok('T17','ส่ง webhook เรื่อง event ที่ไม่เคยเกิด → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T17','ส่ง webhook เรื่อง event ที่ไม่เคยเกิด → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- ฉากของ T18 ถึง T24 · สร้างที่นี่ทั้งหมด ไม่สร้างใน DO block
--
-- บทเรียนจากรอบแรก · DO block ที่คาดว่าจะ raise จะ rollback ของที่มัน
-- สร้างเองไปด้วย ทำให้เทสต์ถัดไปเจอสถานะที่ไม่ได้ตั้งใจ และผ่านหรือพังผิดเหตุ
-- ฉากต้องอยู่นอก block ที่อาจล้ม เสมอ
-- =====================================================================
SELECT advance('op_a','CONFIRMED');   -- op_a มี event seq 1,2,3

-- ส่ง event seq 2 (SUBMITTED) ไปสอง endpoint · ลำดับที่ 1 ของแต่ละคิว
SELECT mk_delivery('wd_a1',     'ep_1', 'op_a', 2, 1, 'operation.submitted');
SELECT mk_delivery('wd_a1_ep2', 'ep_2', 'op_a', 2, 1, 'operation.submitted');
-- ส่ง event seq 3 (CONFIRMED) ไป ep_1 · ลำดับที่ 2 ของคิวนั้น
SELECT mk_delivery('wd_a3',     'ep_1', 'op_a', 3, 2, 'operation.confirmed');

-- op_f สำหรับทดสอบว่า DEAD ไม่บล็อกลำดับถัดไป
SELECT advance('op_f','SUBMITTED');
SELECT advance('op_f','CONFIRMED');
SELECT mk_delivery('wd_f1',     'ep_1', 'op_f', 2, 1, 'operation.submitted');
SELECT mk_delivery('wd_f2',     'ep_1', 'op_f', 3, 2, 'operation.confirmed');
SELECT mk_delivery('wd_f1_ep2', 'ep_2', 'op_f', 2, 1, 'operation.submitted');

-- =====================================================================
-- T18 · event เดียวส่งไป endpoint เดิมซ้ำ → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  PERFORM mk_delivery('wd_dup','ep_1','op_a',2,9,'operation.submitted');
  PERFORM t_ok('T18','event เดียวส่งไป endpoint เดิมซ้ำ → ชน uq_delivery_event', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T18','event เดียวส่งไป endpoint เดิมซ้ำ → ชน uq_delivery_event', true);
END $$;

-- =====================================================================
-- T19 · event เดียวส่งไปหลาย endpoint ได้ · เป็นงานคนละชิ้น
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM webhook_delivery
   WHERE operation_id='op_a' AND event_seq=2;
  PERFORM t_ok('T19','event เดียวส่งได้หลาย endpoint · เป็นงานคนละชิ้น', n = 2);
END $$;

-- =====================================================================
-- T20 · delivery_seq ซ้ำต่อ endpoint และ operation → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  PERFORM mk_delivery('wd_sdup','ep_1','op_a',1,1,'operation.pending');
  PERFORM t_ok('T20','delivery_seq ซ้ำ → ชน uq_delivery_seq', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T20','delivery_seq ซ้ำ → ชน uq_delivery_seq', true);
END $$;

-- =====================================================================
-- T21 · ยิงลำดับที่ 2 ก่อนลำดับที่ 1 จบ → ถูกปฏิเสธ
-- ร้านที่ได้ CONFIRMED ก่อน SUBMITTED จะเขียนสถานะทับผิด
-- =====================================================================
DO $$
BEGIN
  UPDATE webhook_delivery SET status='IN_FLIGHT', claimed_at=now() WHERE id='wd_a3';
  PERFORM t_ok('T21','ยิงลำดับ 2 ก่อนลำดับ 1 จบ → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T21','ยิงลำดับ 2 ก่อนลำดับ 1 จบ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T22 · ลำดับที่ 1 SENT แล้ว ลำดับที่ 2 ยิงได้
-- =====================================================================
UPDATE webhook_delivery SET status='IN_FLIGHT', claimed_at=now() WHERE id='wd_a1';
UPDATE webhook_delivery SET attempt=1 WHERE id='wd_a1';
INSERT INTO webhook_delivery_attempt (id,delivery_id,attempt,started_at,finished_at,
                                      response_status,response_body)
VALUES ('wa_1','wd_a1',1,now() - interval '2 seconds',now(),200,'ok');
UPDATE webhook_delivery SET status='SENT', sent_at=now() WHERE id='wd_a1';

DO $$
DECLARE v delivery_status;
BEGIN
  UPDATE webhook_delivery SET status='IN_FLIGHT', claimed_at=now() WHERE id='wd_a3';
  SELECT status INTO v FROM webhook_delivery WHERE id='wd_a3';
  PERFORM t_ok('T22','ลำดับ 1 SENT แล้ว → ลำดับ 2 ยิงได้', v = 'IN_FLIGHT');
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T22','ลำดับ 1 SENT แล้ว → ลำดับ 2 ยิงได้', false);
END $$;

-- =====================================================================
-- T23 · ลำดับที่ 1 DEAD ก็ไม่บล็อกลำดับถัดไป
-- ร้านที่รับไม่ได้ครั้งหนึ่ง ไม่ควรไม่ได้รับอะไรอีกเลยตลอดกาล
-- =====================================================================
UPDATE webhook_delivery SET status='DEAD', dead_at=now() WHERE id='wd_f1';

DO $$
DECLARE v delivery_status;
BEGIN
  UPDATE webhook_delivery SET status='IN_FLIGHT', claimed_at=now() WHERE id='wd_f2';
  SELECT status INTO v FROM webhook_delivery WHERE id='wd_f2';
  PERFORM t_ok('T23','ลำดับ 1 DEAD → ลำดับ 2 ยังยิงได้', v = 'IN_FLIGHT');
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T23','ลำดับ 1 DEAD → ลำดับ 2 ยังยิงได้', false);
END $$;

-- =====================================================================
-- T24 · คิวของ endpoint หนึ่ง ไม่บล็อก endpoint อื่น
-- =====================================================================
DO $$
DECLARE v delivery_status;
BEGIN
  UPDATE webhook_delivery SET status='IN_FLIGHT', claimed_at=now() WHERE id='wd_f1_ep2';
  SELECT status INTO v FROM webhook_delivery WHERE id='wd_f1_ep2';
  PERFORM t_ok('T24','คิวของ endpoint แยกกัน · ไม่บล็อกข้ามกัน', v = 'IN_FLIGHT');
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T24','คิวของ endpoint แยกกัน · ไม่บล็อกข้ามกัน', false);
END $$;

-- =====================================================================
-- T24b · ส่งซ้ำแถวที่ DEAD ได้ · เป็นแถวใหม่ที่ชี้กลับไปที่ของเดิม
--
-- uq_delivery_event เป็น partial index ที่ครอบเฉพาะ replay_of IS NULL
-- จึงใช้ event_seq เดิมได้ · ถ้าเป็น unique เต็ม การส่งซ้ำจะเป็นไปไม่ได้เลย
-- =====================================================================
DO $$
DECLARE v_ref text; v_seq int;
BEGIN
  INSERT INTO webhook_delivery (id,endpoint_id,operation_id,event_seq,delivery_seq,
                                event_type,payload,signature,signed_at,replay_of)
  VALUES ('wd_f1_rep','ep_1','op_f',2,3,'operation.submitted',
          '{"retry":true}','sig_rep',now(),'wd_f1');
  SELECT replay_of, delivery_seq INTO v_ref, v_seq
    FROM webhook_delivery WHERE id='wd_f1_rep';
  PERFORM t_ok('T24b','ส่งซ้ำแถวที่ DEAD ได้ · event_seq เดิม · ชี้กลับของเดิม',
               v_ref = 'wd_f1' AND v_seq = 3);
EXCEPTION WHEN others THEN
  PERFORM t_ok('T24b','ส่งซ้ำแถวที่ DEAD ได้ · event_seq เดิม · ชี้กลับของเดิม', false);
END $$;

-- =====================================================================
-- T24c · ส่งซ้ำแถวที่ยังไม่ DEAD → ถูกปฏิเสธ
-- ส่งซ้ำแถวที่ SENT แปลว่าร้านได้ของเดิมสองครั้งโดยไม่มีเหตุ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO webhook_delivery (id,endpoint_id,operation_id,event_seq,delivery_seq,
                                event_type,payload,signature,signed_at,replay_of)
  VALUES ('wd_a1_rep','ep_1','op_a',2,4,'operation.submitted',
          '{}','sig',now(),'wd_a1');
  PERFORM t_ok('T24c','ส่งซ้ำแถวที่ SENT แล้ว → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T24c','ส่งซ้ำแถวที่ SENT แล้ว → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T24d · ส่งซ้ำที่อ้าง event อื่น → ถูกปฏิเสธ
-- ไม่ตรงกับของเดิมก็ไม่ใช่การส่งซ้ำ มันคือการส่งเรื่องอื่น
-- =====================================================================
DO $$
BEGIN
  INSERT INTO webhook_delivery (id,endpoint_id,operation_id,event_seq,delivery_seq,
                                event_type,payload,signature,signed_at,replay_of)
  VALUES ('wd_f1_bad','ep_1','op_f',3,4,'operation.confirmed',
          '{}','sig',now(),'wd_f1');
  PERFORM t_ok('T24d','ส่งซ้ำที่อ้าง event อื่น → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T24d','ส่งซ้ำที่อ้าง event อื่น → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T24e · ส่งครั้งแรกของ event เดิมซ้ำ (replay_of เป็น NULL) → ยังถูกปฏิเสธ
-- partial index ยังรักษาข้อที่ต้องการไว้ · ไม่ยิงซ้ำโดยไม่ได้ตั้งใจ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO webhook_delivery (id,endpoint_id,operation_id,event_seq,delivery_seq,
                                event_type,payload,signature,signed_at)
  VALUES ('wd_f1_dup','ep_1','op_f',2,5,'operation.submitted','{}','sig',now());
  PERFORM t_ok('T24e','ส่งครั้งแรกของ event เดิมซ้ำ → ยังถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T24e','ส่งครั้งแรกของ event เดิมซ้ำ → ยังถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T25 · delivery ที่ SENT แล้ว แก้ไม่ได้ · เป็นหลักฐาน
-- =====================================================================
DO $$
BEGIN
  UPDATE webhook_delivery SET attempt = 99 WHERE id='wd_a1';
  PERFORM t_ok('T25','delivery ที่ SENT แล้ว แก้ไม่ได้', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T25','delivery ที่ SENT แล้ว แก้ไม่ได้', true);
END $$;

-- =====================================================================
-- T26 · แก้ payload หรือลายเซ็นของ delivery ที่ยังไม่ส่ง → ถูกปฏิเสธ
-- เซ็นแล้วเปลี่ยนเนื้อหา = ลายเซ็นไม่ตรงกับของจริง
-- =====================================================================
DO $$
BEGIN
  UPDATE webhook_delivery SET payload = '{"แก้":"แล้ว"}' WHERE id='wd_a1_ep2';
  PERFORM t_ok('T26','แก้ payload หลังเซ็นแล้ว → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T26','แก้ payload หลังเซ็นแล้ว → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T27 · attempt ที่ไม่มีทั้งคำตอบและ error → ถูกปฏิเสธ
-- ยิงแล้วไม่ได้คำตอบและไม่มีข้อผิดพลาด เป็นไปไม่ได้
-- =====================================================================
DO $$
BEGIN
  UPDATE webhook_delivery SET attempt=1 WHERE id='wd_f2';
  INSERT INTO webhook_delivery_attempt (id,delivery_id,attempt,started_at,finished_at)
  VALUES ('wa_void','wd_f2',1,now(),now());
  PERFORM t_ok('T27','attempt ที่ไม่มีทั้งคำตอบและ error → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T27','attempt ที่ไม่มีทั้งคำตอบและ error → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T28 · attempt ที่มีทั้งคำตอบและ error → ถูกปฏิเสธ
-- ต้องเป็นอย่างใดอย่างหนึ่ง ไม่ใช่ทั้งสอง
-- =====================================================================
DO $$
BEGIN
  INSERT INTO webhook_delivery_attempt (id,delivery_id,attempt,started_at,finished_at,
                                        response_status,error_note)
  VALUES ('wa_both','wd_f2',1,now(),now(),500,'timeout');
  PERFORM t_ok('T28','attempt ที่มีทั้งคำตอบและ error → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T28','attempt ที่มีทั้งคำตอบและ error → ถูกปฏิเสธ', true);
END $$;

-- ฉากของ T32 · การยิงที่ล้มเหลวจริงหนึ่งครั้ง · สร้างที่ top level
UPDATE webhook_delivery SET attempt=1, next_attempt_at = now() + f_backoff(1)
 WHERE id='wd_f1_ep2';
INSERT INTO webhook_delivery_attempt (id,delivery_id,attempt,started_at,finished_at,
                                      error_note)
VALUES ('wa_fail','wd_f1_ep2',1,now() - interval '3 seconds',now(),
        'connection refused · ร้านไม่ตอบ');

-- =====================================================================
-- T29 · จำนวนครั้งที่ลองต้องตรงกับจำนวนแถว attempt จริง
-- นับเองแล้วเขียนตัวเลขลงไป จะไม่ตรงเมื่อมีใครลืมเขียนแถว
-- =====================================================================
DO $$
BEGIN
  UPDATE webhook_delivery SET attempt=5 WHERE id='wd_f2';
  INSERT INTO webhook_delivery_attempt (id,delivery_id,attempt,started_at,finished_at,
                                        error_note)
  VALUES ('wa_f2_1','wd_f2',1,now(),now(),'connection refused');
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM t_ok('T29','attempt นับไม่ตรงกับแถวจริง → ไม่ผ่าน', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T29','attempt นับไม่ตรงกับแถวจริง → ไม่ผ่าน', true);
END $$;

-- =====================================================================
-- T30 · ลองแล้วล้มเหลว · เวลาหน่วงเพิ่มแบบทวีคูณ
-- =====================================================================
DO $$
DECLARE v1 interval; v3 interval; v6 interval; v20 interval;
BEGIN
  v1 := f_backoff(1); v3 := f_backoff(3); v6 := f_backoff(6); v20 := f_backoff(20);
  PERFORM t_ok('T30','backoff ทวีคูณและมีเพดาน · 1 → 1 นาที · 6 → 32 นาที · เพดาน 60',
               v1 = interval '1 minute'
           AND v3 = interval '4 minutes'
           AND v6 = interval '32 minutes'
           AND v20 = interval '60 minutes');
END $$;

-- =====================================================================
-- T31 · Group E · ไม่มีคอลัมน์ไหนในตาราง attempt ที่สืบจาก chain_event ได้
--
-- ข้อนี้พิสูจน์ด้วยการนับ · ถ้าวันหนึ่งมีใครเพิ่มคอลัมน์ที่สืบได้
-- ข้อนี้จะยังผ่าน แต่ข้อสรุปเรื่อง Group E ต้องถูกทบทวน
-- ที่ตรวจได้จริงคือ ไม่มี foreign key จากตารางนี้ไปหา chain_event
-- =====================================================================
DO $$
DECLARE v_fk int; v_cols int;
BEGIN
  SELECT count(*) INTO v_fk
    FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu
      ON ccu.constraint_name = tc.constraint_name
   WHERE tc.table_name IN ('webhook_delivery_attempt','webhook_delivery','webhook_endpoint')
     AND tc.constraint_type = 'FOREIGN KEY'
     AND ccu.table_name = 'chain_event';
  SELECT count(*) INTO v_cols FROM information_schema.columns
   WHERE table_name = 'webhook_delivery_attempt';
  PERFORM t_ok('T31','Group E · ไม่มี FK จากตารางส่ง webhook ไปหา chain_event',
               v_fk = 0 AND v_cols = 8);
END $$;

-- =====================================================================
-- T32 · Group E · ค่าที่เก็บไว้เป็นสิ่งที่ chain ไม่รู้และจะไม่มีวันรู้
-- ลบตารางนี้แล้ว replay chain_event ใหม่ จะไม่ได้ค่าพวกนี้คืน
-- =====================================================================
DO $$
DECLARE v_status int; v_err text; v_dur boolean;
BEGIN
  SELECT response_status INTO v_status FROM webhook_delivery_attempt WHERE id='wa_1';
  SELECT error_note INTO v_err FROM webhook_delivery_attempt WHERE id='wa_fail';
  SELECT finished_at >= started_at INTO v_dur FROM webhook_delivery_attempt WHERE id='wa_1';
  PERFORM t_ok('T32','Group E · เก็บคำตอบของร้าน เวลาที่ใช้ และ error ที่เจอ',
               v_status = 200 AND v_err IS NOT NULL AND v_dur);
END $$;

-- =====================================================================
-- T33 · คิวงานหยิบเฉพาะที่ถึงเวลาและยัง PENDING
-- =====================================================================
DO $$
DECLARE n_due int; n_future int;
BEGIN
  PERFORM advance('op_g','SUBMITTED');
  PERFORM mk_delivery('wd_g1','ep_1','op_g',2,1,'operation.submitted');
  PERFORM mk_delivery('wd_g2','ep_2','op_g',2,1,'operation.submitted');
  UPDATE webhook_delivery SET next_attempt_at = now() + interval '10 minutes'
   WHERE id='wd_g2';
  SELECT count(*) INTO n_due FROM webhook_delivery
   WHERE status='PENDING' AND next_attempt_at <= now() AND operation_id='op_g';
  SELECT count(*) INTO n_future FROM webhook_delivery
   WHERE status='PENDING' AND next_attempt_at > now() AND operation_id='op_g';
  PERFORM t_ok('T33','คิวหยิบเฉพาะที่ถึงเวลา · ที่ยังไม่ถึงเวลาไม่ถูกหยิบ',
               n_due = 1 AND n_future = 1);
END $$;

-- =====================================================================
-- T34 · IN_FLIGHT ต้องมี claimed_at · ถือไว้โดยไม่บอกว่าเมื่อไรไม่ได้
-- งานที่ค้าง IN_FLIGHT นานเกินกำหนดต้องหาได้
-- =====================================================================
DO $$
BEGIN
  UPDATE webhook_delivery SET status='IN_FLIGHT' WHERE id='wd_g1';
  PERFORM t_ok('T34','IN_FLIGHT โดยไม่มี claimed_at → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T34','IN_FLIGHT โดยไม่มี claimed_at → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T35 · SENT ต้องมี sent_at · DEAD ต้องมี dead_at
-- =====================================================================
DO $$
BEGIN
  UPDATE webhook_delivery SET status='SENT' WHERE id='wd_g2';
  PERFORM t_ok('T35','SENT โดยไม่มี sent_at → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T35','SENT โดยไม่มี sent_at → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T36 · outbox topic ต้องมีเวอร์ชันลงท้าย
-- =====================================================================
DO $$
BEGIN
  INSERT INTO outbox (id,operation_id,topic,payload)
  VALUES ('obx_bad','op_a','operation.status','{}');
  PERFORM t_ok('T36','outbox topic ไม่มี .vN → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T36','outbox topic ไม่มี .vN → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T37 · ปิดท้าย · ทุก operation ที่มีอยู่ สถานะตรงกับ event แถวสุดท้าย
-- =====================================================================
DO $$
DECLARE v_bad int; v_gap int;
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT count(*) INTO v_bad FROM operation o
   WHERE o.status IS DISTINCT FROM (
     SELECT to_status FROM operation_event e
      WHERE e.operation_id = o.id ORDER BY seq DESC LIMIT 1);
  -- และไม่มี operation ไหนที่ seq ขาดช่วง
  SELECT count(*) INTO v_gap FROM (
    SELECT operation_id, count(*) AS n, max(seq) AS mx
      FROM operation_event GROUP BY operation_id) s
   WHERE s.n <> s.mx;
  PERFORM t_ok('T37','ปิดท้าย · ทุก operation สถานะตรง event และ seq ไม่ขาดช่วง',
               v_bad = 0 AND v_gap = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

ROLLBACK;
