-- =====================================================================
-- FEAT-09 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat09 -f tests/acceptance.sql
-- ทุกแถวต้องขึ้น PASS · แถวเดียวที่ FAIL = schema ไม่ให้สิ่งที่ RFD สัญญาไว้
--
-- หัวใจของไฟล์นี้คือ T3 ถึง T8 · ทั้งหกข้อคือ F5 ในรูปของการทดสอบ
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

BEGIN;

CREATE TEMP TABLE result (id text, what text, verdict text);

CREATE OR REPLACE FUNCTION t_ok(p_id text, p_what text, p_pass boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO result VALUES (p_id, p_what, CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END) $$;

CREATE OR REPLACE FUNCTION ref_of(p_id text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to(p_id, 'UTF8')) $$;

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id,name,status) VALUES
  ('mch_a','ร้านผู้ขาย','ACTIVE'),
  ('mch_b','ร้านอื่น','ACTIVE');
INSERT INTO customer (id) VALUES ('cus_1');
INSERT INTO signer (address,key_ref) VALUES
  (decode(repeat('33',20),'hex'),'kms/signer-1');

INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,status,expires_at) VALUES
 ('ct_1','mch_a','คูปองส่วนลด 100', 100000000000000000000, 100,'LIVE', now() + interval '180 days');

-- ร้าน A ถือคูปอง 12 ใบ
INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,state,holder_kind,holder_id)
SELECT 'cc_'||g, 'ct_1', sha256(('CODE-'||g)::bytea), ref_of('cc_'||g),
       'HELD','MERCHANT','mch_a'
FROM generate_series(1,12) g;

-- ร้าน B ถือใบหนึ่งที่ซื้อมา · ใช้ทดสอบการถอดรายการของคนอื่น
INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,state,holder_kind,holder_id)
VALUES ('cc_b1','ct_1', sha256('B1'), ref_of('cc_b1'),'HELD','MERCHANT','mch_b');

-- ---------------------------------------------------------------------
-- helper · สร้างรายการขายที่ ACTIVE แล้ว ครบทั้ง operation + จอง
-- เลียนแบบผลลัพธ์ของ FEAT-08 ที่ FINALIZED ไปเรียบร้อย
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mk_active_listing(
  p_lst text, p_seller_kind holder_kind, p_seller_id text, p_codes text[]
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE c text; i int := 0;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('opc_'||p_lst,
          CASE p_seller_kind WHEN 'MERCHANT' THEN 'merchant:' ELSE 'customer:' END || p_seller_id,
          'LISTING_CREATE','FINALIZED',p_lst,'{}',now());

  INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity,status)
  VALUES (p_lst,p_seller_kind,p_seller_id,'ct_1',80000000000000000000,
          array_length(p_codes,1),'PENDING');

  FOREACH c IN ARRAY p_codes LOOP
    i := i + 1;
    INSERT INTO listing_item (id,listing_id,coupon_code_id)
    VALUES ('li_'||p_lst||'_'||i, p_lst, c);
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_'||p_lst||'_'||i,'opc_'||p_lst,'COUPON_UNIT',c,1);
  END LOOP;

  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_'||p_lst||'_L','opc_'||p_lst,'LISTING',p_lst,1);

  INSERT INTO listing_chain (listing_id,contract_address,chain_listing_id,
                             created_block,created_tx_hash)
  VALUES (p_lst, decode(repeat('aa',20),'hex'), ('x'||substr(md5(p_lst),1,8))::bit(32)::bigint,
          1000, sha256(convert_to(p_lst,'UTF8')));

  UPDATE listing SET status='ACTIVE' WHERE id = p_lst;
END $$;

SELECT mk_active_listing('lst_a','MERCHANT','mch_a', ARRAY['cc_1','cc_2','cc_3']);
SELECT mk_active_listing('lst_b','MERCHANT','mch_b', ARRAY['cc_b1']);
SELECT mk_active_listing('lst_c','MERCHANT','mch_a', ARRAY['cc_5']);
SELECT mk_active_listing('lst_d','MERCHANT','mch_a', ARRAY['cc_6']);
SELECT mk_active_listing('lst_e','MERCHANT','mch_a', ARRAY['cc_7']);
SELECT mk_active_listing('lst_f','MERCHANT','mch_a', ARRAY['cc_8']);
SELECT mk_active_listing('lst_g','MERCHANT','mch_a', ARRAY['cc_9']);
SELECT mk_active_listing('lst_h','MERCHANT','mch_a', ARRAY['cc_10']);
SELECT mk_active_listing('lst_i','MERCHANT','mch_a', ARRAY['cc_11']);

-- ใบที่ยังไม่ขึ้น chain · ใช้ทดสอบว่าถอดของที่ยัง PENDING ไม่ได้
INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload) VALUES
 ('opc_lst_p','merchant:mch_a','LISTING_CREATE','SUBMITTED','lst_p','{}');
INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity,status)
VALUES ('lst_p','MERCHANT','mch_a','ct_1',80000000000000000000,1,'PENDING');
INSERT INTO listing_item (id,listing_id,coupon_code_id) VALUES ('li_p','lst_p','cc_12');

-- =====================================================================
-- T1 · ส่ง Idempotency-Key เดิมซ้ำ → ไม่เกิดงานใหม่            RFD 3 R1
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_1','merchant:mch_a','delist-11111111-2222-3333', sha256('d'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_2','merchant:mch_a','delist-11111111-2222-3333', sha256('d'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T1','ถอดซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · ถอดรายการที่ ACTIVE และเป็นของตัวเอง → ยอมรับ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_a','merchant:mch_a','LISTING_DELETE','lst_a','{}');
  PERFORM t_ok('T2','ถอดรายการ ACTIVE ของตัวเอง → ยอมรับ', true);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T2','ถอดรายการ ACTIVE ของตัวเอง → ยอมรับ', false);
END $$;

-- =====================================================================
-- T3 · F5 ข้อที่หนึ่ง · ถอดรายการของร้านอื่น → ถูกปฏิเสธที่ฐานข้อมูล
-- ระบบเดิมเช็คที่ api · ที่นี่เช็คที่ชั้นเดียวกับที่เขียนข้อมูล
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_b','merchant:mch_a','LISTING_DELETE','lst_b','{}');
  PERFORM t_ok('T3','F5 · ถอดรายการของร้านอื่น → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T3','F5 · ถอดรายการของร้านอื่น → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T4 · F5 ข้อที่สอง · ถอดรายการที่ไม่มีอยู่ → ถูกปฏิเสธ
-- ระบบเดิมเมื่อหาไม่เจอ เซ็ต ownerId = merchantId เองแล้วเดินต่อ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_x','merchant:mch_a','LISTING_DELETE','lst_ไม่มีจริง','{}');
  PERFORM t_ok('T4','F5 · ถอดรายการที่ไม่มีอยู่ → ถูกปฏิเสธ ไม่ใช่กรอกเจ้าของให้', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T4','F5 · ถอดรายการที่ไม่มีอยู่ → ถูกปฏิเสธ ไม่ใช่กรอกเจ้าของให้', true);
END $$;

-- =====================================================================
-- T5 · ไม่ระบุ subject_id → ถูกปฏิเสธ
-- NULL ต้องไม่กลายเป็น "ถอดอะไรก็ได้"
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_n','merchant:mch_a','LISTING_DELETE',NULL,'{}');
  PERFORM t_ok('T5','ถอดโดยไม่ระบุ subject_id → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T5','ถอดโดยไม่ระบุ subject_id → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T6 · ลูกค้าถอดรายการของร้าน → ถูกปฏิเสธ
-- scope เป็นคนละชนิด ไม่ใช่แค่คนละ id
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_c1','customer:mch_a','LISTING_DELETE','lst_c','{}');
  PERFORM t_ok('T6','ลูกค้าถอดรายการของร้าน → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T6','ลูกค้าถอดรายการของร้าน → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T7 · platform admin ถอดได้ทุกใบ · และบันทึกว่าใครสั่ง
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_adm','admin:adm_7','LISTING_DELETE','lst_c','{}');
  INSERT INTO operation_event (id,operation_id,to_status,actor,metadata)
  VALUES ('oev_adm','opd_adm','PENDING','PLATFORM_ADMIN','{"by":"adm_7"}');
  SELECT count(*) INTO n FROM operation_event
   WHERE operation_id='opd_adm' AND actor='PLATFORM_ADMIN';
  PERFORM t_ok('T7','admin ถอดได้ทุกใบ · operation_event บันทึกว่าใครสั่ง', n = 1);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T7','admin ถอดได้ทุกใบ · operation_event บันทึกว่าใครสั่ง', false);
END $$;

-- =====================================================================
-- T8 · actor_scope รูปแบบเพี้ยน → ถูกปฏิเสธที่ CHECK
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_bad','mch_a','LISTING_DELETE','lst_d','{}');
  PERFORM t_ok('T8','actor_scope ไม่มี prefix → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T8','actor_scope ไม่มี prefix → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T9 · ถอดรายการที่ยัง PENDING → ถูกปฏิเสธ
-- ยังไม่มี chain_listing_id จะยกเลิกอะไรบน chain ไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_p','merchant:mch_a','LISTING_DELETE','lst_p','{}');
  PERFORM t_ok('T9','ถอดรายการที่ยัง PENDING → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T9','ถอดรายการที่ยัง PENDING → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T10 · ถอดรายการที่ SOLD แล้ว → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE listing SET status='SOLD' WHERE id='lst_d';
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_d','merchant:mch_a','LISTING_DELETE','lst_d','{}');
  PERFORM t_ok('T10','ถอดรายการที่ SOLD แล้ว → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T10','ถอดรายการที่ SOLD แล้ว → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T11 · ถอดรายการที่ DELISTED แล้ว → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE listing SET status='DELISTED' WHERE id='lst_e';
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_e','merchant:mch_a','LISTING_DELETE','lst_e','{}');
  PERFORM t_ok('T11','ถอดรายการที่ DELISTED แล้ว → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T11','ถอดรายการที่ DELISTED แล้ว → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T12 · สองคำขอถอดใบเดียวกัน ต่าง key → ตัวที่สองชน uq_listing_inflight
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_a2','merchant:mch_a','LISTING_DELETE','lst_a','{}');
  PERFORM t_ok('T12','ถอดใบเดิมซ้ำต่าง key → ชน uq_listing_inflight', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T12','ถอดใบเดิมซ้ำต่าง key → ชน uq_listing_inflight', true);
END $$;

-- =====================================================================
-- T13 · ร้านกดถอดขณะที่ลูกค้ากดซื้อค้างอยู่ → ถอดแพ้
-- นี่คือการแข่งกันจริงของ feature นี้ · ฐานข้อมูลตัดสิน
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload)
  VALUES ('opb_f','customer:cus_1','LISTING_BUY','SUBMITTED','lst_f','{}');
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_f','merchant:mch_a','LISTING_DELETE','lst_f','{}');
  PERFORM t_ok('T13','กดถอดขณะมี LISTING_BUY ค้าง → ถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T13','กดถอดขณะมี LISTING_BUY ค้าง → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T14 · งานที่ MANUAL_REVIEW ยังกันงานใหม่
-- รายการที่รอคนตรวจต้องไม่รับคำขอถอด
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload)
  VALUES ('opb_g','customer:cus_1','LISTING_BUY','MANUAL_REVIEW','lst_g','{}');
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_g','merchant:mch_a','LISTING_DELETE','lst_g','{}');
  PERFORM t_ok('T14','มีงาน MANUAL_REVIEW ค้าง → ถอดไม่ได้', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T14','มีงาน MANUAL_REVIEW ค้าง → ถอดไม่ได้', true);
END $$;

-- =====================================================================
-- T15 · งานที่ CHAIN_REVERTED ไม่กันงานใหม่
-- ซื้อไม่สำเร็จ ร้านต้องถอดได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload)
  VALUES ('opb_h','customer:cus_1','LISTING_BUY','CHAIN_REVERTED','lst_h','{}');
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_h','merchant:mch_a','LISTING_DELETE','lst_h','{}');
  PERFORM t_ok('T15','งานซื้อที่ CHAIN_REVERTED → ร้านถอดได้', true);
EXCEPTION WHEN unique_violation OR check_violation THEN
  PERFORM t_ok('T15','งานซื้อที่ CHAIN_REVERTED → ร้านถอดได้', false);
END $$;

-- =====================================================================
-- T16 · ถอดมีสอง step เรียงกัน · cancelListing ก่อน releaseFromVault
-- =====================================================================
DO $$
DECLARE v text[];
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name) VALUES
   ('st_a1','opd_a',1,'cancelListing'),
   ('st_a2','opd_a',2,'releaseFromVault');
  SELECT array_agg(name ORDER BY step_index) INTO v
    FROM operation_step WHERE operation_id='opd_a';
  PERFORM t_ok('T16','ถอด = 2 step เรียงกัน cancelListing → releaseFromVault',
               v = ARRAY['cancelListing','releaseFromVault']);
END $$;

-- =====================================================================
-- T17 · step_index ซ้ำใน operation เดียว → ชน uq_step_order
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name)
  VALUES ('st_dup','opd_a',1,'cancelListingAgain');
  PERFORM t_ok('T17','step_index ซ้ำ → ชน uq_step_order', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T17','step_index ซ้ำ → ชน uq_step_order', true);
END $$;

-- =====================================================================
-- T18 · ยิงขั้นที่ 2 ก่อนขั้นที่ 1 จบ → ถูกปฏิเสธ
-- releaseFromVault ก่อน cancelListing เปิดช่วงที่รายการโฆษณาของที่ไม่อยู่แล้ว
-- =====================================================================
DO $$
BEGIN
  UPDATE operation_step SET status='SUBMITTED', raw_tx='\xdead', submitted_at=now()
   WHERE id='st_a2';
  PERFORM t_ok('T18','ยิง releaseFromVault ก่อน cancelListing จบ → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T18','ยิง releaseFromVault ก่อน cancelListing จบ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T19 · ขั้นที่ 1 FINALIZED แล้ว ขั้นที่ 2 ยิงได้
-- =====================================================================
DO $$
BEGIN
  UPDATE operation_step SET status='SUBMITTED', raw_tx='\xaa01', submitted_at=now()
   WHERE id='st_a1';
  UPDATE operation_step SET status='FINALIZED',
         tx_hash=decode(repeat('a1',32),'hex'), finalized_at=now()
   WHERE id='st_a1';
  UPDATE operation_step SET status='SUBMITTED', raw_tx='\xaa02', submitted_at=now()
   WHERE id='st_a2';
  PERFORM t_ok('T19','ขั้นที่ 1 FINALIZED แล้ว → ขั้นที่ 2 ยิงได้', true);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T19','ขั้นที่ 1 FINALIZED แล้ว → ขั้นที่ 2 ยิงได้', false);
END $$;

-- =====================================================================
-- T20 · R2 · ยิงออกไปโดยไม่มี raw_tx ที่ commit ไว้ → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name,status)
  VALUES ('st_nr','opd_adm',1,'cancelListing','SUBMITTED');
  PERFORM t_ok('T20','R2 · SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T20','R2 · SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T21 · ปล่อยจองคูปองขณะที่รายการยัง ACTIVE → ถูกปฏิเสธ
-- ปิดรายการก่อน แล้วค่อยปล่อยคูปอง
-- =====================================================================
DO $$
BEGIN
  UPDATE reservation SET released_at=now() WHERE id='rsv_lst_a_1';
  PERFORM t_ok('T21','ปล่อยคูปองขณะรายการยัง ACTIVE → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T21','ปล่อยคูปองขณะรายการยัง ACTIVE → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T22 · ปิดรายการเป็น DELISTED แล้ว ปล่อยคูปองได้
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  UPDATE operation_step SET status='FINALIZED',
         tx_hash=decode(repeat('a2',32),'hex'), finalized_at=now()
   WHERE id='st_a2';
  UPDATE operation SET status='FINALIZED', finalized_at=now() WHERE id='opd_a';
  UPDATE listing_chain SET closed_block=1100, close_reason='CANCELLED',
         closed_tx_hash=decode(repeat('a1',32),'hex') WHERE listing_id='lst_a';
  UPDATE listing SET status='DELISTED' WHERE id='lst_a';
  UPDATE reservation SET released_at=now()
   WHERE operation_id='opc_lst_a' AND released_at IS NULL;
  SELECT count(*) INTO n FROM reservation
   WHERE operation_id='opc_lst_a' AND released_at IS NOT NULL;
  PERFORM t_ok('T22','ปิดเป็น DELISTED แล้ว → ปล่อยจองได้ทั้ง 4 แถว', n = 4);
END $$;

-- =====================================================================
-- T23 · closed_at ถูกเติมให้เอง เมื่อปิดรายการ
-- =====================================================================
DO $$
DECLARE v timestamptz; a timestamptz;
BEGIN
  SELECT closed_at, active_at INTO v, a FROM listing WHERE id='lst_a';
  PERFORM t_ok('T23','ปิดรายการ → closed_at ถูกเติมและไม่ก่อนหน้า active_at',
               v IS NOT NULL AND a IS NOT NULL AND v >= a);
END $$;

-- =====================================================================
-- T24 · คูปองไม่เคยเปลี่ยน state ตลอดการลงขายและถอด
-- ยังเป็น HELD อยู่ในมือร้านเดิม · การลงขายเป็นเรื่องของ reservation
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM coupon_code
   WHERE id IN ('cc_1','cc_2','cc_3')
     AND state='HELD' AND holder_kind='MERCHANT' AND holder_id='mch_a';
  PERFORM t_ok('T24','ถอดเสร็จ · คูปองยัง HELD กับร้านเดิม ไม่เปลี่ยน state', n = 3);
END $$;

-- =====================================================================
-- T25 · ปล่อยจองแล้ว เอาคูปองใบเดิมไปลงขายใบใหม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('opc_lst_new','merchant:mch_a','LISTING_CREATE','FINALIZED','lst_new','{}',now());
  INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity,status)
  VALUES ('lst_new','MERCHANT','mch_a','ct_1',90000000000000000000,1,'PENDING');
  INSERT INTO listing_item (id,listing_id,coupon_code_id) VALUES ('li_new','lst_new','cc_1');
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_new','opc_lst_new','COUPON_UNIT','cc_1',1);
  PERFORM t_ok('T25','ถอดแล้วลงขายใบเดิมใหม่ได้ · จองใหม่ผ่าน', true);
EXCEPTION WHEN unique_violation OR check_violation THEN
  PERFORM t_ok('T25','ถอดแล้วลงขายใบเดิมใหม่ได้ · จองใหม่ผ่าน', false);
END $$;

-- =====================================================================
-- T26 · DELISTED → ACTIVE ไม่ได้ · ถอดแล้วปลุกใบเดิมไม่ได้
-- =====================================================================
DO $$
BEGIN
  UPDATE listing SET status='ACTIVE' WHERE id='lst_a';
  PERFORM t_ok('T26','DELISTED → ACTIVE → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T26','DELISTED → ACTIVE → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T27 · มีคนซื้อตัดหน้า · ถอด CHAIN_REVERTED แล้วรายการกลายเป็น SOLD
-- การยกเลิกที่ revert ไม่ใช่ error ของระบบ · เป็นผลลัพธ์ปกติของการแข่ง
-- =====================================================================
DO $$
DECLARE v listing_status; r listing_close_reason;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opd_i','merchant:mch_a','LISTING_DELETE','lst_i','{}');
  -- chain บอกว่า cancel ไม่ผ่านเพราะมีคนซื้อไปแล้ว
  UPDATE operation SET status='CHAIN_REVERTED',
         error_note='cancelListing revert · listing ถูกซื้อไปแล้ว' WHERE id='opd_i';
  UPDATE listing_chain SET closed_block=1200, close_reason='SOLD',
         closed_tx_hash=decode(repeat('b9',32),'hex') WHERE listing_id='lst_i';
  UPDATE listing SET status='SOLD' WHERE id='lst_i';
  SELECT l.status, c.close_reason INTO v, r
    FROM listing l JOIN listing_chain c ON c.listing_id=l.id WHERE l.id='lst_i';
  PERFORM t_ok('T27','ซื้อตัดหน้า · ถอด CHAIN_REVERTED → รายการเป็น SOLD',
               v = 'SOLD' AND r = 'SOLD');
END $$;

-- =====================================================================
-- T28 · ปิดด้วยเหตุผลหนึ่งแล้ว เขียนทับด้วยอีกเหตุผลไม่ได้
-- SOLD จะกลายเป็น CANCELLED ย้อนหลังไม่ได้
-- =====================================================================
DO $$
BEGIN
  UPDATE listing_chain SET close_reason='CANCELLED' WHERE listing_id='lst_i';
  PERFORM t_ok('T28','close_reason SOLD → CANCELLED → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T28','close_reason SOLD → CANCELLED → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T29 · outbox topic ต้องมีเวอร์ชันลงท้าย
-- =====================================================================
DO $$
BEGIN
  INSERT INTO outbox (id,operation_id,topic,payload)
  VALUES ('obx_bad','opd_a','listing.delete','{}');
  PERFORM t_ok('T29','outbox topic ไม่มี .vN → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T29','outbox topic ไม่มี .vN → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T30 · claim outbox ด้วย index เฉพาะแถวที่ยังไม่ส่ง
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  INSERT INTO outbox (id,operation_id,topic,payload) VALUES
   ('obx_1','opd_a','listing.delete.v1','{}'),
   ('obx_2','opd_adm','listing.delete.v1','{}');
  UPDATE outbox SET sent_at=now() WHERE id='obx_1';
  SELECT count(*) INTO n FROM outbox WHERE sent_at IS NULL;
  PERFORM t_ok('T30','outbox ที่ส่งแล้วไม่ถูกหยิบซ้ำ', n = 1);
END $$;

-- =====================================================================
-- T31 · tx_hash ซ้ำข้าม operation → ชน uq_step_txhash
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name,status,raw_tx,tx_hash)
  VALUES ('st_h1','opd_h',1,'cancelListing','FINALIZED','\xbb',
          decode(repeat('a1',32),'hex'));
  PERFORM t_ok('T31','tx_hash ซ้ำข้าม operation → ถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T31','tx_hash ซ้ำข้าม operation → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T32 · nonce ซ้ำของ signer เดียวกัน → ชน uq_signer_nonce
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name,status,raw_tx,
                              signer_address,nonce) VALUES
   ('st_n1','opd_h',1,'cancelListing','SUBMITTED','\xc1',
    decode(repeat('33',20),'hex'),41),
   ('st_n2','opd_adm',2,'releaseFromVault','SUBMITTED','\xc2',
    decode(repeat('33',20),'hex'),41);
  PERFORM t_ok('T32','nonce ซ้ำของ signer เดียวกัน → ถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T32','nonce ซ้ำของ signer เดียวกัน → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T33 · listing_chain เปลี่ยน chain_listing_id ไม่ได้
-- =====================================================================
DO $$
BEGIN
  UPDATE listing_chain SET chain_listing_id=999999 WHERE listing_id='lst_c';
  PERFORM t_ok('T33','แก้ chain_listing_id → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T33','แก้ chain_listing_id → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T34 · อ่าน log ช่วงเดิมซ้ำได้                              RFD 5 D2
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_1',1100,decode(repeat('bb',32),'hex'),decode(repeat('a1',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_2',1100,decode(repeat('bb',32),'hex'),decode(repeat('a1',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T34','อ่าน log ช่วงเดิมซ้ำ → chain_event ไม่เกิดแถวซ้ำ', n1 = 1 AND n2 = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

ROLLBACK;
