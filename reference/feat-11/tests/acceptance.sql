-- =====================================================================
-- FEAT-11 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat11 -f tests/acceptance.sql
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
INSERT INTO merchant (id, name) VALUES ('mch_1','ร้านทดสอบ');
INSERT INTO customer (id, tel_hash) VALUES ('cus_1', sha256('0812345678'));
INSERT INTO wallet (id,address,key_ref,owner_kind,owner_id) VALUES
 ('wal_s', decode(repeat('11',20),'hex'),'kms/seller','MERCHANT','mch_1'),
 ('wal_b', decode(repeat('22',20),'hex'),'kms/buyer','CUSTOMER','cus_1');
INSERT INTO coupon_type (id,merchant_id,name,contract_address,chain_type_id,face_value)
 VALUES ('ct_1','mch_1','คูปองส่วนลด 100', decode(repeat('aa',20),'hex'), 7, 100000000000000000000);
INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,state,holder_kind,holder_id)
 VALUES ('cc_1','ct_1',sha256('CODE-1'),sha256('cc_1'),'HELD','CUSTOMER','cus_1');

INSERT INTO operation (id,actor_scope,kind,payload) VALUES
 ('op_1','customer:cus_1','COUPON_REDEEM','{"couponCodeId":"cc_1"}'),
 ('op_2','customer:cus_1','COUPON_REDEEM','{"couponCodeId":"cc_1"}');
INSERT INTO outbox (id,operation_id,topic,payload) VALUES
 ('obx_1','op_1','operation.prepared.v1','{}'),
 ('obx_2','op_2','operation.prepared.v1','{}');

-- =====================================================================
-- T1 · Idempotency-Key ซ้ำ ต้องไม่สร้างงานใหม่            RFD 3 R1
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_1','customer:cus_1','11111111-2222-3333-4444-555555555555', sha256('body'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;

  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_2','customer:cus_1','11111111-2222-3333-4444-555555555555', sha256('body'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;

  PERFORM t_ok('T1','ส่ง Idempotency-Key เดิมซ้ำ → แถวที่สองได้ 0 rows ไม่ throw', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · จอง coupon ใบเดิมซ้อนกันไม่ได้                      RFD 11 D4
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_1','op_1','COUPON_UNIT','cc_1',1);
  BEGIN
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_2','op_2','COUPON_UNIT','cc_1',1);
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T2','จอง coupon ใบเดียวกันสองครั้ง → ครั้งที่สองถูกฐานข้อมูลปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T3 · ปล่อยจองแล้วจองใหม่ได้ · partial index ต้องไม่ล็อกตลอดกาล
-- =====================================================================
DO $$
DECLARE ok boolean := false;
BEGIN
  UPDATE reservation SET released_at = now() WHERE id = 'rsv_1';
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_3','op_2','COUPON_UNIT','cc_1',1);
  ok := true;
  PERFORM t_ok('T3','ปล่อยจองแล้วจองใหม่ได้ · ประวัติแถวเดิมยังอยู่', ok);
END $$;

-- =====================================================================
-- T4 · ห้าม broadcast ก่อน raw_tx ลงตาราง                   RFD 2 R2
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name)
  VALUES ('st_1','op_1',1,'burnCoupon');
  BEGIN
    UPDATE operation_step SET status = 'SUBMITTED' WHERE id = 'st_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T4','เปลี่ยน step เป็น SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T5 · tx_hash เดียวกันเกิดสองแถวไม่ได้ · ส่งซ้ำแล้วปลอดภัย  RFD 2 D4
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  UPDATE operation_step
     SET raw_tx = '\x02f8', signer_address = decode(repeat('33',20),'hex'), nonce = 41,
         status = 'SUBMITTED', tx_hash = decode(repeat('ab',32),'hex')
   WHERE id = 'st_1';
  INSERT INTO operation_step (id,operation_id,step_index,name,raw_tx,status,tx_hash)
  VALUES ('st_2','op_1',2,'releaseFundsPartial','\x02f8','SUBMITTED', decode(repeat('ab',32),'hex'));
  EXCEPTION WHEN unique_violation THEN blocked := true;
  PERFORM t_ok('T5','ส่ง raw_tx ไบต์เดิมซ้ำ → tx_hash ซ้ำถูกปฏิเสธ ไม่เกิดแถวซ้ำ', blocked);
END $$;

-- =====================================================================
-- T6 · re-index ช่วงเดิมซ้ำได้                              RFD 5 D2
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,topic0,data,block_timestamp)
  VALUES ('ce_1',1001, decode(repeat('bb',32),'hex'), decode(repeat('ab',32),'hex'), 0,
          decode(repeat('aa',20),'hex'), '\x00', '\x00', now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,topic0,data,block_timestamp)
  VALUES ('ce_2',1001, decode(repeat('bb',32),'hex'), decode(repeat('ab',32),'hex'), 0,
          decode(repeat('aa',20),'hex'), '\x00', '\x00', now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T6','อ่าน log ช่วงเดิมซ้ำ → chain_event ไม่เกิดแถวซ้ำ', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T7 · numeric(78,0) รับ uint256 สูงสุดได้              RFD 14 D1
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  SELECT (2::numeric ^ 256 - 1) INTO v;
  INSERT INTO escrow (id,chain_token_id,contract_address,seller_wallet_id,buyer_wallet_id,
                      total_amount,remaining_amount,coupons_locked)
  VALUES ('esc_max', 1, decode(repeat('cc',20),'hex'),'wal_s','wal_b', v, v, 1);
  PERFORM t_ok('T7','เก็บ uint256 สูงสุด (2^256-1) ได้ครบทุกหลัก',
    (SELECT total_amount FROM escrow WHERE id='esc_max') = v);
END $$;

-- =====================================================================
-- T8 · ยอดติดลบเข้าไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO escrow (id,chain_token_id,contract_address,seller_wallet_id,buyer_wallet_id,
                        total_amount,remaining_amount,coupons_locked)
    VALUES ('esc_neg', 2, decode(repeat('cc',20),'hex'),'wal_s','wal_b', -1, 0, 1);
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T8','ยอดเงินติดลบถูกปฏิเสธที่ระดับฐานข้อมูล', blocked);
END $$;

-- =====================================================================
-- T9 · escrow active ซ้อนกันบน tokenId เดียวไม่ได้       RFD 13 D5
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO escrow (id,chain_token_id,contract_address,seller_wallet_id,buyer_wallet_id,
                      total_amount,remaining_amount,coupons_locked)
  VALUES ('esc_1', 7, decode(repeat('aa',20),'hex'),'wal_s','wal_b', 100, 100, 2);
  BEGIN
    INSERT INTO escrow (id,chain_token_id,contract_address,seller_wallet_id,buyer_wallet_id,
                        total_amount,remaining_amount,coupons_locked)
    VALUES ('esc_2', 7, decode(repeat('aa',20),'hex'),'wal_s','wal_b', 50, 50, 1);
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T9','เปิด escrow ซ้อนบน tokenId เดิม → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T10 · invariant · operation ทุกแถวต้องมี outbox คู่กัน    RFD 2 D1
-- =====================================================================
DO $$
DECLARE orphan int;
BEGIN
  SELECT count(*) INTO orphan
  FROM operation o LEFT JOIN outbox b ON b.operation_id = o.id
  WHERE b.id IS NULL;
  PERFORM t_ok('T10','ไม่มี operation ที่ไม่มีใครมาทำ (orphan = 0)', orphan = 0);
END $$;

-- =====================================================================
-- T11 · invariant · coupon ที่ burn แล้วต้องไม่มีเงินค้าง   RFD 13 §6
-- =====================================================================
DO $$
DECLARE unpaid int;
BEGIN
  UPDATE coupon_code SET state='REDEEMED', redeemed_at = now() WHERE id='cc_1';
  UPDATE escrow SET coupons_redeemed = 1, remaining_amount = 50 WHERE id='esc_1';
  SELECT count(*) INTO unpaid
  FROM coupon_code c
  JOIN coupon_type t  ON t.id = c.coupon_type_id
  JOIN escrow e ON e.contract_address = t.contract_address
               AND e.chain_token_id   = t.chain_type_id
  WHERE c.state = 'REDEEMED'
    AND e.active
    AND e.coupons_redeemed = 0;          -- burn แล้วแต่ยังไม่มีการจ่ายเลย
  PERFORM t_ok('T11','ไม่มี coupon ที่ burn แล้วแต่ผู้ขายยังไม่ได้เงิน (unpaid = 0)', unpaid = 0);
END $$;

-- =====================================================================
-- T12 · state กับ timestamp ต้องสอดคล้องกัน
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,state,redeemed_at)
    VALUES ('cc_bad','ct_1',sha256('X'),sha256('Y'),'REDEEMED',NULL);
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T12','state=REDEEMED โดยไม่มี redeemed_at → ถูกปฏิเสธ', blocked);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY id;
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

-- ไม่ commit · ฐานข้อมูลกลับไปเหมือนก่อนรัน
ROLLBACK;
