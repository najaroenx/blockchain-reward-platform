-- =====================================================================
-- FEAT-04 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat04 -f tests/acceptance.sql
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

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id, name, status) VALUES
  ('mch_ok','ร้านที่พร้อมแล้ว','ACTIVE'),
  ('mch_new','ร้านที่เพิ่งสมัคร','PENDING');
INSERT INTO signer (address, key_ref) VALUES (decode(repeat('33',20),'hex'),'kms/signer-1');
INSERT INTO wallet (id,address,key_ref,owner_kind,owner_id)
VALUES ('wal_1', decode(repeat('11',20),'hex'),'kms/m1','MERCHANT','mch_ok');

-- =====================================================================
-- T1 · ส่ง Idempotency-Key เดิมซ้ำ → ไม่เกิดงานใหม่            RFD 3 R1
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_1','merchant:mch_ok','11111111-2222-3333-4444-555555555555', sha256('body'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_2','merchant:mch_ok','11111111-2222-3333-4444-555555555555', sha256('body'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T1','สร้าง point type ซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · ร้านที่ยังไม่ ACTIVE สร้าง point type ไม่ได้
--      บังคับด้วย trigger ไม่ใช่แค่ guard ใน api
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
    VALUES ('pt_bad','mch_new','แต้มร้านใหม่','NEWP',18);
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T2','ร้านที่ status ยังไม่ ACTIVE สร้าง point type ไม่ได้', blocked);
END $$;

-- =====================================================================
-- T3 · สัญลักษณ์ต้องเป็นตัวใหญ่ล้วน 2-11 ตัว
-- =====================================================================
DO $$
DECLARE lower_ok boolean := false; too_short boolean := false; has_space boolean := false;
BEGIN
  INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
  VALUES ('pt_1','mch_ok','แต้มสะสมสุขใจ','SUKJAI',18);

  BEGIN
    INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
    VALUES ('pt_x1','mch_ok','ก','sukjai',18);
  EXCEPTION WHEN check_violation THEN lower_ok := true; END;
  BEGIN
    INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
    VALUES ('pt_x2','mch_ok','ข','S',18);
  EXCEPTION WHEN check_violation THEN too_short := true; END;
  BEGIN
    INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
    VALUES ('pt_x3','mch_ok','ค','SUK JAI',18);
  EXCEPTION WHEN check_violation THEN has_space := true; END;

  PERFORM t_ok('T3','symbol ที่เป็นตัวเล็ก สั้นไป หรือมีช่องว่าง → ถูกปฏิเสธ',
               lower_ok AND too_short AND has_space);
END $$;

-- =====================================================================
-- T4 · decimals ต้องอยู่ในช่วง 0-30                          RFD 14
-- =====================================================================
DO $$
DECLARE too_big boolean := false; negative boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
    VALUES ('pt_x4','mch_ok','ง','BIGD',31);
  EXCEPTION WHEN check_violation THEN too_big := true; END;
  BEGIN
    INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
    VALUES ('pt_x5','mch_ok','จ','NEGD',-1);
  EXCEPTION WHEN check_violation THEN negative := true; END;
  PERFORM t_ok('T4','decimals เกิน 30 หรือติดลบ → ถูกปฏิเสธ', too_big AND negative);
END $$;

-- =====================================================================
-- T5 · ร้านเดียวกันใช้ symbol ซ้ำไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
    VALUES ('pt_dup','mch_ok','ชื่ออื่น','SUKJAI',18);
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T5','ร้านเดียวกันใช้ symbol ซ้ำ → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T6 · ชื่อซ้ำแบบไม่สนตัวพิมพ์และช่องว่างหน้าหลัง ก็ไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
    VALUES ('pt_dup2','mch_ok','  แต้มสะสมสุขใจ ','OTHER',18);
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T6','ชื่อเดียวกันที่มีช่องว่างหน้าหลัง → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T7 · deploy ล้มแล้ว ชื่อและ symbol ถูกปล่อยคืนให้ใช้ใหม่ได้
--      partial index ครอบเฉพาะแถวที่ status <> FAILED
-- =====================================================================
DO $$
DECLARE reused boolean := false;
BEGIN
  INSERT INTO point_type (id,merchant_id,name,symbol,decimals,status)
  VALUES ('pt_fail','mch_ok','แต้มที่ล้ม','FAILP',18,'FAILED');
  INSERT INTO point_type (id,merchant_id,name,symbol,decimals)
  VALUES ('pt_retry','mch_ok','แต้มที่ล้ม','FAILP',18);
  reused := true;
  PERFORM t_ok('T7','deploy ล้มแล้วใช้ชื่อและ symbol เดิมสร้างใหม่ได้', reused);
END $$;

-- =====================================================================
-- T8 · point type หนึ่งอันมีงาน deploy ค้างทีละงานเดียว
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_1','merchant:mch_ok','POINT_TYPE_CREATE','pt_1','{}');
  INSERT INTO outbox (id,operation_id,topic,payload)
  VALUES ('obx_1','op_1','point.type.create.v1','{}');
  BEGIN
    INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
    VALUES ('op_2','merchant:mch_ok','POINT_TYPE_CREATE','pt_1','{}');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T8','สั่ง deploy point type เดิมซ้อนกัน → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T9 · ค่าที่มาจาก chain แก้ไม่ได้หลังถูกเขียน
--      deploy ใหม่ต้องเป็น point_type แถวใหม่ ไม่ใช่แก้แถวเดิม
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO point_type_chain (point_type_id, contract_address, deployed_block,
                                deployed_tx_hash, genesis_at, epoch_seconds, validity_epochs)
  VALUES ('pt_1', decode(repeat('aa',20),'hex'), 1001,
          decode(repeat('ab',32),'hex'), now(), 2592000, 4);
  BEGIN
    UPDATE point_type_chain SET contract_address = decode(repeat('bb',20),'hex')
     WHERE point_type_id = 'pt_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T9','แก้ contract_address ของ point type ที่ deploy แล้ว → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T10 · contract address เดียวกันผูกกับ point type สองอันไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_type_chain (point_type_id, contract_address, deployed_block,
                                  deployed_tx_hash, genesis_at, epoch_seconds, validity_epochs)
    VALUES ('pt_retry', decode(repeat('aa',20),'hex'), 1002,
            decode(repeat('cd',32),'hex'), now(), 2592000, 4);
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T10','contract address เดียวกันผูกกับสอง point type → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T11 · ค่า epoch ต้องเป็นบวก · ไม่งั้นคำนวณวันหมดอายุไม่ได้   RFD 10
-- =====================================================================
DO $$
DECLARE zero_epoch boolean := false; zero_validity boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_type_chain (point_type_id, contract_address, deployed_block,
                                  deployed_tx_hash, genesis_at, epoch_seconds, validity_epochs)
    VALUES ('pt_retry', decode(repeat('ba',20),'hex'), 1003,
            decode(repeat('ce',32),'hex'), now(), 0, 4);
  EXCEPTION WHEN check_violation THEN zero_epoch := true; END;
  BEGIN
    INSERT INTO point_type_chain (point_type_id, contract_address, deployed_block,
                                  deployed_tx_hash, genesis_at, epoch_seconds, validity_epochs)
    VALUES ('pt_retry', decode(repeat('bc',20),'hex'), 1004,
            decode(repeat('cf',32),'hex'), now(), 2592000, 0);
  EXCEPTION WHEN check_violation THEN zero_validity := true; END;
  PERFORM t_ok('T11','epoch_seconds หรือ validity_epochs เป็น 0 → ถูกปฏิเสธ',
               zero_epoch AND zero_validity);
END $$;

-- =====================================================================
-- T12 · ห้าม broadcast ก่อน raw_tx ลงตาราง                   RFD 2 R2
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name)
  VALUES ('st_1','op_1',1,'createPointToken');
  BEGIN
    UPDATE operation_step SET status = 'SUBMITTED' WHERE id = 'st_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T12','เปลี่ยน step เป็น SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T13 · topic ของ outbox ต้องมีเวอร์ชันในชื่อ                RFD 7 D9
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO outbox (id,operation_id,topic,payload)
    VALUES ('obx_bad','op_1','point.type.create','{}');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T13','topic ที่ไม่มีเวอร์ชันต่อท้าย → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T14 · อ่าน log ช่วงเดิมซ้ำได้                              RFD 5 D2
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
  PERFORM t_ok('T14','อ่าน log ช่วงเดิมซ้ำ → chain_event ไม่เกิดแถวซ้ำ', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T15 · invariant · point type ที่ LIVE ต้องมีแถวฝั่ง chain เสมอ
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  UPDATE point_type SET status = 'LIVE', live_at = now() WHERE id = 'pt_1';
  SELECT count(*) INTO bad
  FROM point_type p LEFT JOIN point_type_chain c ON c.point_type_id = p.id
  WHERE p.status = 'LIVE' AND c.point_type_id IS NULL;
  PERFORM t_ok('T15','ไม่มี point type ที่ LIVE แต่ยังไม่มี contract', bad = 0);
END $$;

-- =====================================================================
-- T16 · invariant · operation ทุกแถวต้องมี outbox คู่กัน      RFD 2 D1
-- =====================================================================
DO $$
DECLARE orphan int;
BEGIN
  SELECT count(*) INTO orphan
  FROM operation o LEFT JOIN outbox b ON b.operation_id = o.id
  WHERE b.id IS NULL;
  PERFORM t_ok('T16','ไม่มี operation ที่ไม่มีใครมาทำ (orphan = 0)', orphan = 0);
END $$;

-- =====================================================================
-- T17 · ตาราง point_type_chain rebuild ได้ · ไม่มีคอลัมน์ที่มาจากร้าน
--      ตรวจโครงสร้างตาราง ไม่ใช่ตรวจข้อมูล                   RFD 6 §3.2
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'point_type_chain'
    AND column_name IN ('name','symbol','decimals','status','merchant_id');
  PERFORM t_ok('T17','point_type_chain ไม่มีคอลัมน์ที่มาจากร้าน · replay ได้ทั้งตาราง', bad = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

-- ไม่ commit · ฐานข้อมูลกลับไปเหมือนก่อนรัน
ROLLBACK;
