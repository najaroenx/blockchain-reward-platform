-- =====================================================================
-- FEAT-08 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat08 -f tests/acceptance.sql
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

CREATE OR REPLACE FUNCTION ref_of(p_id text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to(p_id, 'UTF8')) $$;

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id,name,status) VALUES
  ('mch_a','ร้านผู้ขาย','ACTIVE'),
  ('mch_b','ร้านอื่น','ACTIVE');
INSERT INTO signer (address,key_ref) VALUES (decode(repeat('33',20),'hex'),'kms/signer-1');

INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,status,expires_at) VALUES
 ('ct_1','mch_a','คูปองส่วนลด 100', 100000000000000000000, 100,'LIVE', now() + interval '180 days'),
 ('ct_2','mch_a','คูปองคนละประเภท',  50000000000000000000, 100,'LIVE', now() + interval '180 days'),
 ('ct_old','mch_a','คูปองหมดอายุ',   10000000000000000000, 100,'LIVE', now() - interval '1 day');

-- ร้าน A ถือคูปอง ct_1 อยู่ 10 ใบ
INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,state,holder_kind,holder_id)
SELECT 'cc_'||g, 'ct_1', sha256(('CODE-'||g)::bytea), ref_of('cc_'||g), 'HELD','MERCHANT','mch_a'
FROM generate_series(1,10) g;

-- ใบที่ยังไม่มีผู้ถือ · ใบของร้านอื่น · ใบคนละประเภท
INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,state,holder_kind,holder_id) VALUES
 ('cc_unheld','ct_1', sha256('U'), ref_of('cc_unheld'),'ISSUED',NULL,NULL),
 ('cc_other', 'ct_1', sha256('O'), ref_of('cc_other'), 'HELD','MERCHANT','mch_b'),
 ('cc_type2', 'ct_2', sha256('T'), ref_of('cc_type2'), 'HELD','MERCHANT','mch_a');

INSERT INTO operation (id,actor_scope,kind,subject_id,payload) VALUES
 ('op_1','merchant:mch_a','LISTING_CREATE','lst_1','{}'),
 ('op_2','merchant:mch_a','LISTING_CREATE','lst_2','{}');
INSERT INTO outbox (id,operation_id,topic,payload) VALUES
 ('obx_1','op_1','listing.create.v1','{}'),
 ('obx_2','op_2','listing.create.v1','{}');

-- =====================================================================
-- T1 · ส่ง Idempotency-Key เดิมซ้ำ → ไม่เกิดงานใหม่            RFD 3 R1
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_1','merchant:mch_a','11111111-2222-3333-4444-555555555555', sha256('b'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_2','merchant:mch_a','11111111-2222-3333-4444-555555555555', sha256('b'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T1','ลงขายซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · ขายบางส่วนได้ · 5 จาก 10 ใบ · ระบุได้ว่าใบไหนบ้าง
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity)
  VALUES ('lst_1','MERCHANT','mch_a','ct_1', 80000000000000000000, 5);
  INSERT INTO listing_item (id,listing_id,coupon_code_id)
  SELECT 'li_'||g,'lst_1','cc_'||g FROM generate_series(1,5) g;
  SELECT count(*) INTO n FROM listing_item WHERE listing_id = 'lst_1';
  PERFORM t_ok('T2','ขาย 5 จาก 10 ใบได้ · ระบุใบที่ขายเจาะจง', n = 5);
END $$;

-- =====================================================================
-- T3 · ใส่ใบเกิน quantity ที่ประกาศไว้ไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO listing_item (id,listing_id,coupon_code_id) VALUES ('li_x','lst_1','cc_6');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T3','ใส่ใบที่ 6 ทั้งที่ประกาศ quantity 5 → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T4 · ลงขายใบที่ไม่ได้อยู่ในมือตัวเองไม่ได้                    RFD 12 · F5
--      ข้อนี้คือสิ่งที่ระบบเดิมพลาด · เช็คที่ api แล้วมีทางลัดข้ามไปได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity)
  VALUES ('lst_2','MERCHANT','mch_a','ct_1', 80000000000000000000, 1);
  BEGIN
    INSERT INTO listing_item (id,listing_id,coupon_code_id) VALUES ('li_y','lst_2','cc_other');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T4','ลงขายคูปองของร้านอื่น → ถูกปฏิเสธที่ฐานข้อมูล', blocked);
END $$;

-- =====================================================================
-- T5 · ลงขายใบที่ยังไม่มีผู้ถือไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO listing_item (id,listing_id,coupon_code_id) VALUES ('li_z','lst_2','cc_unheld');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T5','ลงขายใบที่สถานะยังไม่ HELD → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T6 · ใบคนละประเภทกับรายการขายใส่ไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO listing_item (id,listing_id,coupon_code_id) VALUES ('li_w','lst_2','cc_type2');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T6','ใส่คูปองคนละประเภทกับรายการขาย → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T7 · ลงขายคูปองที่หมดอายุไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  -- ประเภทนี้ตั้ง expires_at ไว้ในอดีตตั้งแต่ fixture
  -- ใช้ pg_sleep ไม่ได้ เพราะ now() ใน transaction หยุดอยู่ที่เวลาเริ่ม transaction
  INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,state,holder_kind,holder_id)
  VALUES ('cc_exp','ct_old', sha256('E'), ref_of('cc_exp'),'HELD','MERCHANT','mch_a');
  INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity)
  VALUES ('lst_old','MERCHANT','mch_a','ct_old', 1, 1);
  BEGIN
    INSERT INTO listing_item (id,listing_id,coupon_code_id) VALUES ('li_e','lst_old','cc_exp');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T7','ลงขายคูปองที่หมดอายุไปแล้ว → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T8 · ราคาต้องมากกว่า 0
-- =====================================================================
DO $$
DECLARE zero_price boolean := false; neg_price boolean := false;
BEGIN
  BEGIN
    INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity)
    VALUES ('lst_p0','MERCHANT','mch_a','ct_1', 0, 1);
  EXCEPTION WHEN check_violation THEN zero_price := true; END;
  BEGIN
    INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity)
    VALUES ('lst_pn','MERCHANT','mch_a','ct_1', -1, 1);
  EXCEPTION WHEN check_violation THEN neg_price := true; END;
  PERFORM t_ok('T8','ราคา 0 หรือติดลบ → ถูกปฏิเสธ', zero_price AND neg_price);
END $$;

-- =====================================================================
-- T9 · คูปองใบเดียวกันอยู่ในสองรายการขายพร้อมกันไม่ได้         RFD 12 D3
--      บังคับด้วย partial unique index บน reservation
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_c1','op_1','COUPON_UNIT','cc_1', 1);
  BEGIN
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_c1b','op_2','COUPON_UNIT','cc_1', 1);
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T9','จองคูปองใบเดียวกันในสองรายการขาย → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T10 · รายการขายเองก็จองซ้อนไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_l1','op_1','LISTING','lst_1', 1);
  BEGIN
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_l1b','op_2','LISTING','lst_1', 1);
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T10','จองรายการขายเดิมซ้อนกัน → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T11 · ลงขาย = 3 step เรียงกัน · นี่คือเหตุผลที่ operation_step ต้องมี
-- =====================================================================
DO $$
DECLARE names text[];
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name) VALUES
   ('st_1','op_1',1,'approveCoupon'),
   ('st_2','op_1',2,'createListing'),
   ('st_3','op_1',3,'lockInVault');
  SELECT array_agg(name ORDER BY step_index) INTO names
    FROM operation_step WHERE operation_id = 'op_1';
  PERFORM t_ok('T11','ลงขายมี 3 step เรียง approveCoupon → createListing → lockInVault',
               names = ARRAY['approveCoupon','createListing','lockInVault']);
END $$;

-- =====================================================================
-- T12 · step_index ซ้ำในงานเดียวกันไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO operation_step (id,operation_id,step_index,name)
    VALUES ('st_dup','op_1',2,'createListing');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T12','step_index ซ้ำในงานเดียวกัน → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T13 · ห้าม broadcast ก่อน raw_tx ลงตาราง                   RFD 2 R2
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    UPDATE operation_step SET status = 'SUBMITTED' WHERE id = 'st_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T13','เปลี่ยน step เป็น SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T14 · nonce ของ signer ตัวหนึ่งใช้ซ้ำไม่ได้                  RFD 4
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  UPDATE operation_step SET raw_tx='\x02f8', signer_address=decode(repeat('33',20),'hex'),
         nonce=90, status='SUBMITTED', tx_hash=decode(repeat('a1',32),'hex') WHERE id='st_1';
  BEGIN
    UPDATE operation_step SET raw_tx='\x02f8', signer_address=decode(repeat('33',20),'hex'),
           nonce=90, status='SUBMITTED', tx_hash=decode(repeat('a2',32),'hex') WHERE id='st_2';
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T14','ใช้ nonce เดิมของ signer ตัวเดิมซ้ำ → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T15 · ปล่อยจองก่อนงานจบไม่ได้                               RFD 9
-- =====================================================================
DO $$
DECLARE too_early boolean := false; released boolean := false;
BEGIN
  BEGIN
    UPDATE reservation SET released_at = now() WHERE id = 'rsv_c1';
  EXCEPTION WHEN check_violation THEN too_early := true; END;

  UPDATE operation SET status = 'CHAIN_REVERTED' WHERE id = 'op_1';
  UPDATE reservation SET released_at = now() WHERE id = 'rsv_c1';
  released := true;
  PERFORM t_ok('T15','ปล่อยจองก่อนงานจบไม่ได้ · พอ CHAIN_REVERTED แล้วปล่อยได้',
               too_early AND released);
END $$;

-- =====================================================================
-- T16 · ปล่อยแล้วคูปองใบนั้นลงขายใหม่ได้
-- =====================================================================
DO $$
DECLARE ok boolean := false;
BEGIN
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_c1c','op_2','COUPON_UNIT','cc_1', 1);
  ok := true;
  PERFORM t_ok('T16','ปล่อยจองแล้วคูปองใบเดิมลงขายใหม่ได้', ok);
END $$;

-- =====================================================================
-- T17 · ค่าที่มาจาก chain แก้ไม่ได้หลังถูกเขียน
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO listing_chain (listing_id,contract_address,chain_listing_id,created_block,created_tx_hash)
  VALUES ('lst_1', decode(repeat('aa',20),'hex'), 42, 1001, decode(repeat('ab',32),'hex'));
  BEGIN
    UPDATE listing_chain SET chain_listing_id = 99 WHERE listing_id = 'lst_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T17','แก้ chain_listing_id ของรายการที่อยู่บน chain แล้ว → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T18 · chain listing id เดียวกันผูกกับสองรายการไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO listing_chain (listing_id,contract_address,chain_listing_id,created_block,created_tx_hash)
    VALUES ('lst_2', decode(repeat('aa',20),'hex'), 42, 1002, decode(repeat('cd',32),'hex'));
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T18','contract + chain_listing_id ซ้ำ → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T19 · รายการขายอันเดียวมีงานค้างทีละงานเดียว
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_d1','merchant:mch_a','LISTING_DELETE','lst_1','{}');
  INSERT INTO outbox (id,operation_id,topic,payload)
  VALUES ('obx_d1','op_d1','listing.delete.v1','{}');
  BEGIN
    INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
    VALUES ('op_d2','merchant:mch_a','LISTING_DELETE','lst_1','{}');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T19','สั่งงานกับรายการขายเดิมซ้อนกัน → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T20 · ราคาเก็บ uint256 สูงสุดได้                            RFD 14 D1
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  SELECT (2::numeric ^ 256 - 1) INTO v;
  INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity)
  VALUES ('lst_max','MERCHANT','mch_a','ct_1', v, 1);
  PERFORM t_ok('T20','เก็บราคาเป็น uint256 สูงสุดได้ครบทุกหลัก',
    (SELECT unit_price FROM listing WHERE id='lst_max') = v);
END $$;

-- =====================================================================
-- T21 · topic ของ outbox ต้องมีเวอร์ชันในชื่อ                RFD 7 D9
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO outbox (id,operation_id,topic,payload)
    VALUES ('obx_bad','op_2','listing.create','{}');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T21','topic ที่ไม่มีเวอร์ชันต่อท้าย → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T22 · invariant · operation ทุกแถวต้องมี outbox คู่กัน      RFD 2 D1
-- =====================================================================
DO $$
DECLARE orphan int;
BEGIN
  SELECT count(*) INTO orphan FROM operation o
  LEFT JOIN outbox b ON b.operation_id = o.id WHERE b.id IS NULL;
  PERFORM t_ok('T22','ไม่มี operation ที่ไม่มีใครมาทำ (orphan = 0)', orphan = 0);
END $$;

-- =====================================================================
-- T23 · invariant · รายการขายที่ ACTIVE ต้องมีแถวฝั่ง chain
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  UPDATE listing SET status = 'ACTIVE', active_at = now() WHERE id = 'lst_1';
  SELECT count(*) INTO bad
  FROM listing l LEFT JOIN listing_chain c ON c.listing_id = l.id
  WHERE l.status = 'ACTIVE' AND c.listing_id IS NULL;
  PERFORM t_ok('T23','ไม่มีรายการขายที่ ACTIVE แต่ยังไม่อยู่บน chain', bad = 0);
END $$;

-- =====================================================================
-- T24 · invariant · ทุกใบในรายการขายต้องเป็นใบที่ผู้ขายถืออยู่
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM listing_item i
  JOIN listing l ON l.id = i.listing_id
  JOIN coupon_code c ON c.id = i.coupon_code_id
  WHERE c.holder_kind IS DISTINCT FROM l.seller_kind
     OR c.holder_id   IS DISTINCT FROM l.seller_id;
  PERFORM t_ok('T24','ทุกใบในรายการขายอยู่ในมือผู้ขายจริง', bad = 0);
END $$;

-- =====================================================================
-- T25 · อ่าน log ช่วงเดิมซ้ำได้                              RFD 5 D2
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,topic0,data,block_timestamp)
  VALUES ('ce_1',1001,decode(repeat('bb',32),'hex'),decode(repeat('ab',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,topic0,data,block_timestamp)
  VALUES ('ce_2',1001,decode(repeat('bb',32),'hex'),decode(repeat('ab',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T25','อ่าน log ช่วงเดิมซ้ำ → chain_event ไม่เกิดแถวซ้ำ', n1 = 1 AND n2 = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

-- ไม่ commit · ฐานข้อมูลกลับไปเหมือนก่อนรัน
ROLLBACK;
