-- =====================================================================
-- FEAT-07 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat07 -f tests/acceptance.sql
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

-- ตัวช่วยสร้าง code_ref ให้ถูกกฎ · เหมือนที่ service ต้องทำ
CREATE OR REPLACE FUNCTION ref_of(p_id text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to(p_id, 'UTF8')) $$;

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id,name,status) VALUES
  ('mch_ok','ร้านที่พร้อมแล้ว','ACTIVE'),
  ('mch_new','ร้านที่เพิ่งสมัคร','PENDING');
INSERT INTO signer (address,key_ref) VALUES (decode(repeat('33',20),'hex'),'kms/signer-1');

INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,status,expires_at,live_at)
VALUES ('ct_1','mch_ok','คูปองส่วนลด 100 บาท', 100000000000000000000, 3,'LIVE',
        now() + interval '180 days', now());
INSERT INTO coupon_type_chain (coupon_type_id,contract_address,chain_type_id,deployed_block,deployed_tx_hash)
VALUES ('ct_1', decode(repeat('aa',20),'hex'), 7, 1001, decode(repeat('ab',32),'hex'));

INSERT INTO operation (id,actor_scope,kind,subject_id,payload) VALUES
 ('op_1','merchant:mch_ok','COUPON_ISSUE','ct_1','{}');
INSERT INTO outbox (id,operation_id,topic,payload)
VALUES ('obx_1','op_1','coupon.issue.v1','{}');
INSERT INTO issue_batch (id,coupon_type_id,operation_id,quantity)
VALUES ('ib_1','ct_1','op_1',3);

-- =====================================================================
-- T1 · ส่ง Idempotency-Key เดิมซ้ำ → ไม่เกิดงานใหม่            RFD 3 R1
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_1','merchant:mch_ok','11111111-2222-3333-4444-555555555555', sha256('b'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_2','merchant:mch_ok','11111111-2222-3333-4444-555555555555', sha256('b'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T1','ออกคูปองซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · ร้านที่ยังไม่ ACTIVE สร้างประเภทคูปองไม่ได้ · บังคับด้วย trigger
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,expires_at)
    VALUES ('ct_bad','mch_new','คูปองร้านใหม่',1,10, now() + interval '30 days');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T2','ร้านที่ status ยังไม่ ACTIVE สร้างประเภทคูปองไม่ได้', blocked);
END $$;

-- =====================================================================
-- T3 · ชื่อซ้ำในร้านเดียวไม่ได้ · ไม่สนตัวพิมพ์และช่องว่างหน้าหลัง
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,expires_at)
    VALUES ('ct_dup','mch_ok','  คูปองส่วนลด 100 บาท ',1,10, now() + interval '30 days');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T3','ชื่อประเภทคูปองซ้ำในร้านเดียว → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T4 · deploy ล้มแล้วชื่อถูกปล่อยคืน · partial index ครอบเฉพาะที่ไม่ FAILED
-- =====================================================================
DO $$
DECLARE reused boolean := false;
BEGIN
  INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,status,expires_at)
  VALUES ('ct_fail','mch_ok','คูปองที่ล้ม',1,10,'FAILED', now() + interval '30 days');
  INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,expires_at)
  VALUES ('ct_retry','mch_ok','คูปองที่ล้ม',1,10, now() + interval '30 days');
  reused := true;
  PERFORM t_ok('T4','deploy ล้มแล้วใช้ชื่อเดิมสร้างใหม่ได้', reused);
END $$;

-- =====================================================================
-- T5 · วันหมดอายุต้องอยู่หลังวันสร้าง · และ supply ต้องเป็นบวก
-- =====================================================================
DO $$
DECLARE bad_expiry boolean := false; bad_supply boolean := false;
BEGIN
  BEGIN
    INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,expires_at)
    VALUES ('ct_x1','mch_ok','ก',1,10, now() - interval '1 day');
  EXCEPTION WHEN check_violation THEN bad_expiry := true; END;
  BEGIN
    INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,expires_at)
    VALUES ('ct_x2','mch_ok','ข',1,0, now() + interval '30 days');
  EXCEPTION WHEN check_violation THEN bad_supply := true; END;
  PERFORM t_ok('T5','วันหมดอายุก่อนวันสร้าง หรือ supply เป็น 0 → ถูกปฏิเสธ',
               bad_expiry AND bad_supply);
END $$;

-- =====================================================================
-- T6 · code_ref ต้องเท่ากับ sha256(id) เสมอ                 RFD 11 §3.3
--      นี่คือสิ่งที่ทำให้ projector คำนวณ code_ref เองได้โดยไม่ต้องรู้ plaintext
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,issue_batch_id)
    VALUES ('cc_bad','ct_1', sha256('CODE-BAD'), sha256('something-else'),'ib_1');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T6','code_ref ที่ไม่ใช่ sha256(id) → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T7 · ออกรหัสได้ตามจำนวนที่ประกาศ · เกินไม่ได้
-- =====================================================================
DO $$
DECLARE n int; blocked boolean := false;
BEGIN
  INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,issue_batch_id) VALUES
   ('cc_1','ct_1', sha256('CODE-1'), ref_of('cc_1'),'ib_1'),
   ('cc_2','ct_1', sha256('CODE-2'), ref_of('cc_2'),'ib_1'),
   ('cc_3','ct_1', sha256('CODE-3'), ref_of('cc_3'),'ib_1');
  SELECT count(*) INTO n FROM coupon_code WHERE coupon_type_id = 'ct_1';
  BEGIN
    INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,issue_batch_id)
    VALUES ('cc_4','ct_1', sha256('CODE-4'), ref_of('cc_4'),'ib_1');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T7','ออกครบ 3 ใบตาม supply · ใบที่ 4 → ถูกปฏิเสธ', n = 3 AND blocked);
END $$;

-- =====================================================================
-- T8 · ยกเลิกใบหนึ่งแล้วออกใหม่ได้ · VOIDED ปล่อยโควตาคืน
-- =====================================================================
DO $$
DECLARE ok boolean := false;
BEGIN
  UPDATE coupon_code SET state = 'VOIDED' WHERE id = 'cc_3';
  INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,issue_batch_id)
  VALUES ('cc_5','ct_1', sha256('CODE-5'), ref_of('cc_5'),'ib_1');
  ok := true;
  PERFORM t_ok('T8','ยกเลิกใบหนึ่งแล้วออกใบใหม่ได้ · VOIDED ปล่อยโควตาคืน', ok);
END $$;

-- =====================================================================
-- T9 · รหัสเดียวกันออกสองใบไม่ได้ · code_hash unique ทั้งระบบ
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    -- ใช้ประเภทอื่นที่ยังมีโควตาเหลือ จะได้เห็นว่าชนที่ code_hash ไม่ใช่ที่ supply
    INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref)
    VALUES ('cc_col','ct_retry', sha256('CODE-1'), ref_of('cc_col'));
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T9','รหัสชนกันข้ามประเภทคูปอง (code_hash ซ้ำทั้งระบบ) → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T10 · ตาราง coupon_code ไม่มีคอลัมน์เก็บรหัสแบบ plaintext
--       ตรวจโครงสร้างตาราง ไม่ใช่ตรวจข้อมูล                 RFD 11 §3.3
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'coupon_code'
    AND (column_name ~* '(code|secret|plain)'
         AND column_name NOT IN ('code_hash','code_ref'));
  PERFORM t_ok('T10','coupon_code ไม่มีคอลัมน์เก็บรหัสแบบ plaintext เลย', bad = 0);
END $$;

-- =====================================================================
-- T11 · สถานะ HELD ต้องมีผู้ถือ · REDEEMED ต้องมีเวลาที่ใช้
-- =====================================================================
DO $$
DECLARE held_no_holder boolean := false; redeemed_no_time boolean := false;
BEGIN
  BEGIN
    UPDATE coupon_code SET state = 'HELD' WHERE id = 'cc_1';
  EXCEPTION WHEN check_violation THEN held_no_holder := true; END;
  BEGIN
    UPDATE coupon_code SET state = 'REDEEMED' WHERE id = 'cc_2';
  EXCEPTION WHEN check_violation THEN redeemed_no_time := true; END;
  PERFORM t_ok('T11','HELD โดยไม่มีผู้ถือ หรือ REDEEMED โดยไม่มีเวลา → ถูกปฏิเสธ',
               held_no_holder AND redeemed_no_time);
END $$;

-- =====================================================================
-- T12 · ผู้ถือต้องระบุทั้งชนิดและรหัส ไม่ใช่แค่อย่างใดอย่างหนึ่ง
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    UPDATE coupon_code SET holder_kind = 'CUSTOMER' WHERE id = 'cc_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T12','ใส่ holder_kind โดยไม่ใส่ holder_id → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T13 · ค่าที่มาจาก chain แก้ไม่ได้หลังถูกเขียน
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    UPDATE coupon_type_chain SET chain_type_id = 99 WHERE coupon_type_id = 'ct_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T13','แก้ chain_type_id ของประเภทที่ deploy แล้ว → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T14 · contract + type id เดียวกันผูกกับสองประเภทไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO coupon_type_chain (coupon_type_id,contract_address,chain_type_id,deployed_block,deployed_tx_hash)
    VALUES ('ct_retry', decode(repeat('aa',20),'hex'), 7, 1002, decode(repeat('cd',32),'hex'));
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T14','contract address + chain_type_id ซ้ำ → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T15 · ประเภทคูปองอันเดียวสั่ง deploy ซ้อนไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_d1','merchant:mch_ok','COUPON_TYPE_CREATE','ct_retry','{}');
  INSERT INTO outbox (id,operation_id,topic,payload)
  VALUES ('obx_d1','op_d1','coupon.type.create.v1','{}');
  BEGIN
    INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
    VALUES ('op_d2','merchant:mch_ok','COUPON_TYPE_CREATE','ct_retry','{}');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T15','สั่ง deploy ประเภทคูปองเดิมซ้อนกัน → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T16 · mint เป็นชุด · step ละไม่เกิน 500 ใบ
-- =====================================================================
DO $$
DECLARE n int; too_many boolean := false;
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name,mint_count) VALUES
   ('st_1','op_1',1,'mintCoupon',500),
   ('st_2','op_1',2,'mintCoupon',500),
   ('st_3','op_1',3,'mintCoupon',200);
  SELECT count(*) INTO n FROM operation_step WHERE operation_id = 'op_1';
  BEGIN
    INSERT INTO operation_step (id,operation_id,step_index,name,mint_count)
    VALUES ('st_bad','op_d1',1,'mintCoupon',501);
  EXCEPTION WHEN check_violation THEN too_many := true;
  END;
  PERFORM t_ok('T16','mint 1200 ใบ = 3 step · step ที่เกิน 500 → ถูกปฏิเสธ', n = 3 AND too_many);
END $$;

-- =====================================================================
-- T17 · ห้าม broadcast ก่อน raw_tx ลงตาราง                   RFD 2 R2
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    UPDATE operation_step SET status = 'SUBMITTED' WHERE id = 'st_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T17','เปลี่ยน step เป็น SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T18 · nonce ของ signer ตัวหนึ่งใช้ซ้ำไม่ได้                  RFD 4
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  UPDATE operation_step SET raw_tx='\x02f8', signer_address=decode(repeat('33',20),'hex'),
         nonce=80, status='SUBMITTED', tx_hash=decode(repeat('a1',32),'hex') WHERE id='st_1';
  BEGIN
    UPDATE operation_step SET raw_tx='\x02f8', signer_address=decode(repeat('33',20),'hex'),
           nonce=80, status='SUBMITTED', tx_hash=decode(repeat('a2',32),'hex') WHERE id='st_2';
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T18','ใช้ nonce เดิมของ signer ตัวเดิมซ้ำ → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T19 · มูลค่าหน้าคูปองเก็บ uint256 สูงสุดได้                 RFD 14 D1
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  SELECT (2::numeric ^ 256 - 1) INTO v;
  INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,expires_at)
  VALUES ('ct_max','mch_ok','คูปองมูลค่าสูงสุด', v, 1, now() + interval '30 days');
  PERFORM t_ok('T19','เก็บ face_value เป็น uint256 สูงสุดได้ครบทุกหลัก',
    (SELECT face_value FROM coupon_type WHERE id='ct_max') = v);
END $$;

-- =====================================================================
-- T20 · invariant · ประเภทคูปองที่ LIVE ต้องมีแถวฝั่ง chain
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM coupon_type t LEFT JOIN coupon_type_chain c ON c.coupon_type_id = t.id
  WHERE t.status = 'LIVE' AND c.coupon_type_id IS NULL;
  PERFORM t_ok('T20','ไม่มีประเภทคูปองที่ LIVE แต่ยังไม่มี contract', bad = 0);
END $$;

-- =====================================================================
-- T21 · invariant · ไม่มีรหัสที่ออกเกิน supply ของประเภทตัวเอง
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM (
    SELECT t.id, t.total_supply, count(c.id) FILTER (WHERE c.state <> 'VOIDED') AS issued
      FROM coupon_type t LEFT JOIN coupon_code c ON c.coupon_type_id = t.id
     GROUP BY t.id, t.total_supply
  ) x WHERE x.issued > x.total_supply;
  PERFORM t_ok('T21','ไม่มีประเภทไหนที่ออกรหัสเกิน supply ที่ประกาศไว้', bad = 0);
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
-- T23 · อ่าน log ช่วงเดิมซ้ำได้                              RFD 5 D2
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
  PERFORM t_ok('T23','อ่าน log ช่วงเดิมซ้ำ → chain_event ไม่เกิดแถวซ้ำ', n1 = 1 AND n2 = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

-- ไม่ commit · ฐานข้อมูลกลับไปเหมือนก่อนรัน
ROLLBACK;
