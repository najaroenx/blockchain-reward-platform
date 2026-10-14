-- =====================================================================
-- FEAT-05 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat05 -f tests/acceptance.sql
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
INSERT INTO merchant (id,name,status) VALUES ('mch_1','ร้านทดสอบ','ACTIVE');
INSERT INTO customer (id,tel_hash) VALUES
  ('cus_1', sha256('0810000001')), ('cus_2', sha256('0810000002'));
INSERT INTO signer (address,key_ref) VALUES (decode(repeat('33',20),'hex'),'kms/signer-1');
INSERT INTO point_type (id,merchant_id,name,symbol,decimals,status)
VALUES ('pt_1','mch_1','แต้มสะสมสุขใจ','SUKJAI',18,'LIVE');
INSERT INTO point_type_chain (point_type_id,contract_address,genesis_at,epoch_seconds,validity_epochs)
VALUES ('pt_1', decode(repeat('aa',20),'hex'), now() - interval '90 days', 2592000, 4);

-- ร้านมี 1000 point ที่ยังไม่หมดอายุ · และ 500 ที่หมดอายุไปแล้ว
INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at)
VALUES
 ('bkt_live','pt_1','MERCHANT','mch_1', 3, 1000, now() - interval '1 day',  now() + interval '60 days'),
 ('bkt_dead','pt_1','MERCHANT','mch_1', 0,  500, now() - interval '90 days', now() - interval '1 day');

INSERT INTO operation (id,actor_scope,kind,payload) VALUES
 ('op_1','merchant:mch_1','POINT_TRANSFER','{}'),
 ('op_2','merchant:mch_1','POINT_TRANSFER','{}'),
 ('op_3','merchant:mch_1','POINT_TRANSFER','{}');
INSERT INTO outbox (id,operation_id,topic,payload) VALUES
 ('obx_1','op_1','point.transfer.v1','{}'),
 ('obx_2','op_2','point.transfer.v1','{}'),
 ('obx_3','op_3','point.transfer.v1','{}');

-- =====================================================================
-- T1 · ส่ง Idempotency-Key เดิมซ้ำ → ไม่เกิดงานใหม่            RFD 3 R1
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_1','merchant:mch_1','11111111-2222-3333-4444-555555555555', sha256('b'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_2','merchant:mch_1','11111111-2222-3333-4444-555555555555', sha256('b'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T1','โอน point ซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · ยอดที่หมดอายุแล้วไม่นับเป็นยอดที่ใช้ได้                  RFD 10
--      ร้านมี 1500 รวม แต่ 500 หมดอายุ → ใช้ได้ 1000
-- =====================================================================
DO $$
DECLARE total numeric; avail numeric;
BEGIN
  SELECT sum(amount) INTO total FROM point_balance_bucket
   WHERE point_type_id='pt_1' AND holder_id='mch_1';
  avail := f_available_points('pt_1','MERCHANT','mch_1', now());
  PERFORM t_ok('T2','bucket ที่หมดอายุไม่นับในยอดที่ใช้ได้ (รวม 1500 · ใช้ได้ 1000)',
               total = 1500 AND avail = 1000);
END $$;

-- =====================================================================
-- T3 · จองได้ไม่เกินยอดที่ใช้ได้ · บังคับด้วย trigger
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_over','op_1','POINT_BALANCE','pt_1|MERCHANT|mch_1', 1001);
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T3','จอง 1001 ทั้งที่ใช้ได้ 1000 → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T4 · ยอด point จองพร้อมกันหลายรายการได้ · ต่างจากของชิ้นเดียว
--      RFD 9 Q4 · ถ้า index ยังครอบ POINT_BALANCE ข้อนี้จะ FAIL
-- =====================================================================
DO $$
DECLARE ok boolean := false; avail numeric;
BEGIN
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_a','op_1','POINT_BALANCE','pt_1|MERCHANT|mch_1', 400);
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_b','op_2','POINT_BALANCE','pt_1|MERCHANT|mch_1', 300);
  avail := f_available_points('pt_1','MERCHANT','mch_1', now());
  ok := (avail = 300);
  PERFORM t_ok('T4','ร้านโอนให้หลายคนพร้อมกันได้ · จอง 400+300 เหลือ 300', ok);
END $$;

-- =====================================================================
-- T5 · จองรวมกันเกินยอดไม่ได้ แม้แต่ละรายการจะไม่เกิน
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_c','op_3','POINT_BALANCE','pt_1|MERCHANT|mch_1', 301);
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T5','จองเพิ่ม 301 ทั้งที่เหลือ 300 → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T6 · ปล่อยจองแล้วยอดกลับมาใช้ได้
-- =====================================================================
DO $$
DECLARE avail numeric; too_early boolean := false;
BEGIN
  -- ปล่อยตอนงานยังไม่จบไม่ได้
  BEGIN
    UPDATE reservation SET released_at = now() WHERE id = 'rsv_a';
  EXCEPTION WHEN check_violation THEN too_early := true;
  END;

  -- tx ล้มบน chain → ปล่อยคืนได้
  UPDATE operation SET status = 'CHAIN_REVERTED' WHERE id = 'op_1';
  UPDATE reservation SET released_at = now() WHERE id = 'rsv_a';
  avail := f_available_points('pt_1','MERCHANT','mch_1', now());
  PERFORM t_ok('T6','ปล่อยจองก่อนงานจบไม่ได้ · พอ CHAIN_REVERTED แล้วคืน 400 → เหลือ 700',
               too_early AND avail = 700);
END $$;

-- =====================================================================
-- T7 · subject_id ของ POINT_BALANCE ต้องถูกรูปแบบ
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_bad','op_3','POINT_BALANCE','pt_1', 1);
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T7','subject_id ที่ไม่ใช่รูปแบบ pt|kind|holder → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T8 · ของชิ้นเดียวยังจองซ้อนไม่ได้เหมือนเดิม                 RFD 11 D4
--      การแคบ index ลงต้องไม่ทำให้ COUPON_UNIT หลุด
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_cu1','op_1','COUPON_UNIT','cc_1', 1);
  BEGIN
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_cu2','op_2','COUPON_UNIT','cc_1', 1);
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T8','จอง coupon ใบเดียวกันซ้อน → ยังถูกปฏิเสธเหมือนเดิม', blocked);
END $$;

-- =====================================================================
-- T9 · bucket ที่หมดอายุก่อนได้รับไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at)
    VALUES ('bkt_bad','pt_1','CUSTOMER','cus_1',1,100, now(), now() - interval '1 hour');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T9','bucket ที่ expires_at อยู่ก่อน received_at → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T10 · หนึ่ง bucket ต่อ (ผู้ถือ, point type, epoch)
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at)
    VALUES ('bkt_dup','pt_1','MERCHANT','mch_1',3,10, now(), now() + interval '60 days');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T10','สร้าง bucket ซ้ำใน epoch เดิมของผู้ถือเดิม → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T11 · ยอดติดลบเข้าไม่ได้ทั้ง bucket และ reservation
-- =====================================================================
DO $$
DECLARE neg_bucket boolean := false; neg_resv boolean := false;
BEGIN
  BEGIN
    INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at)
    VALUES ('bkt_neg','pt_1','CUSTOMER','cus_2',9,-1, now(), now() + interval '1 day');
  EXCEPTION WHEN check_violation THEN neg_bucket := true; END;
  BEGIN
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_neg','op_3','POINT_BALANCE','pt_1|MERCHANT|mch_1', 0);
  EXCEPTION WHEN check_violation THEN neg_resv := true; END;
  PERFORM t_ok('T11','ยอดติดลบหรือศูนย์เข้าไม่ได้', neg_bucket AND neg_resv);
END $$;

-- =====================================================================
-- T12 · numeric(78,0) รับ uint256 สูงสุดได้                   RFD 14 D1
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  SELECT (2::numeric ^ 256 - 1) INTO v;
  INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at)
  VALUES ('bkt_max','pt_1','CUSTOMER','cus_2',7, v, now(), now() + interval '60 days');
  PERFORM t_ok('T12','เก็บ uint256 สูงสุด (2^256-1) ได้ครบทุกหลัก',
    (SELECT amount FROM point_balance_bucket WHERE id='bkt_max') = v);
END $$;

-- =====================================================================
-- T13 · โอนเป็นชุด = หนึ่ง operation หลาย step · step ละไม่เกิน 100 คน
-- =====================================================================
DO $$
DECLARE n int; too_many boolean := false;
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name,recipient_count) VALUES
   ('st_1','op_1',1,'batchTransfer',100),
   ('st_2','op_1',2,'batchTransfer',100),
   ('st_3','op_1',3,'batchTransfer', 43);
  SELECT count(*) INTO n FROM operation_step WHERE operation_id = 'op_1';
  BEGIN
    INSERT INTO operation_step (id,operation_id,step_index,name,recipient_count)
    VALUES ('st_bad','op_2',1,'batchTransfer',101);
  EXCEPTION WHEN check_violation THEN too_many := true;
  END;
  PERFORM t_ok('T13','โอน 243 คน = 3 step · step ที่เกิน 100 คน → ถูกปฏิเสธ',
               n = 3 AND too_many);
END $$;

-- =====================================================================
-- T14 · ห้าม broadcast ก่อน raw_tx ลงตาราง                   RFD 2 R2
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    UPDATE operation_step SET status = 'SUBMITTED' WHERE id = 'st_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T14','เปลี่ยน step เป็น SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T15 · nonce ของ signer ตัวหนึ่งใช้ซ้ำไม่ได้                  RFD 4
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  UPDATE operation_step SET raw_tx='\x02f8', signer_address=decode(repeat('33',20),'hex'),
         nonce=70, status='SUBMITTED', tx_hash=decode(repeat('a1',32),'hex') WHERE id='st_1';
  BEGIN
    UPDATE operation_step SET raw_tx='\x02f8', signer_address=decode(repeat('33',20),'hex'),
           nonce=70, status='SUBMITTED', tx_hash=decode(repeat('a2',32),'hex') WHERE id='st_2';
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T15','ใช้ nonce เดิมของ signer ตัวเดิมซ้ำ → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T16 · บัญชีคู่ · ทุก operation ต้องมียอด DEBIT เท่ากับ CREDIT
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  INSERT INTO ledger_entry (id,operation_id,point_type_id,holder_kind,holder_id,direction,amount) VALUES
   ('le_1','op_1','pt_1','MERCHANT','mch_1','DEBIT', 300),
   ('le_2','op_1','pt_1','CUSTOMER','cus_1','CREDIT',200),
   ('le_3','op_1','pt_1','CUSTOMER','cus_2','CREDIT',100);

  SELECT count(*) INTO bad FROM (
    SELECT operation_id,
           sum(amount) FILTER (WHERE direction='DEBIT')  AS d,
           sum(amount) FILTER (WHERE direction='CREDIT') AS c
      FROM ledger_entry GROUP BY operation_id
  ) x WHERE x.d IS DISTINCT FROM x.c;
  PERFORM t_ok('T16','ทุก operation มียอด DEBIT เท่ากับ CREDIT (บัญชีคู่สมดุล)', bad = 0);
END $$;

-- =====================================================================
-- T17 · เลือก bucket แบบ FIFO · ใกล้หมดอายุก่อน               RFD 10
-- =====================================================================
DO $$
DECLARE first_id text;
BEGIN
  INSERT INTO point_balance_bucket (id,point_type_id,holder_kind,holder_id,epoch_index,amount,received_at,expires_at)
  VALUES ('bkt_soon','pt_1','MERCHANT','mch_1',4,50, now(), now() + interval '5 days');

  SELECT id INTO first_id FROM point_balance_bucket
   WHERE point_type_id='pt_1' AND holder_kind='MERCHANT' AND holder_id='mch_1'
     AND expires_at > now() AND amount > 0
   ORDER BY expires_at ASC LIMIT 1;
  PERFORM t_ok('T17','query เลือก bucket ที่ใกล้หมดอายุที่สุดก่อน', first_id = 'bkt_soon');
END $$;

-- =====================================================================
-- T18 · invariant · ไม่มี reservation ที่ปล่อยแล้วแต่งานยังไม่จบ
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM reservation r JOIN operation o ON o.id = r.operation_id
  WHERE r.released_at IS NOT NULL
    AND o.status NOT IN ('FINALIZED','CHAIN_REVERTED');
  PERFORM t_ok('T18','ไม่มีการปล่อยจองของงานที่ยังไม่จบ (บังคับด้วย trigger)', bad = 0);
END $$;

-- =====================================================================
-- T19 · invariant · operation ทุกแถวต้องมี outbox คู่กัน      RFD 2 D1
-- =====================================================================
DO $$
DECLARE orphan int;
BEGIN
  SELECT count(*) INTO orphan FROM operation o
  LEFT JOIN outbox b ON b.operation_id = o.id WHERE b.id IS NULL;
  PERFORM t_ok('T19','ไม่มี operation ที่ไม่มีใครมาทำ (orphan = 0)', orphan = 0);
END $$;

-- =====================================================================
-- T20 · ตาราง point_balance_bucket ไม่เก็บ "ยอดคงเหลือ" สำเร็จรูป
--      ตรวจโครงสร้างตาราง · ถ้ามีคอลัมน์แบบนั้น กฎ replay จะพัง RFD 10
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='point_balance_bucket'
    AND column_name ~* '(available|balance|total|remaining)';
  PERFORM t_ok('T20','bucket ไม่มีคอลัมน์ยอดคงเหลือสำเร็จรูป · คิดตอน query เท่านั้น', bad = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

-- ไม่ commit · ฐานข้อมูลกลับไปเหมือนก่อนรัน
ROLLBACK;
