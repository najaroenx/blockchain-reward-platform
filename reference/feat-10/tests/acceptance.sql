-- =====================================================================
-- FEAT-10 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat10 -f tests/acceptance.sql
-- ทุกแถวต้องขึ้น PASS · แถวเดียวที่ FAIL = schema ไม่ให้สิ่งที่ RFD สัญญาไว้
--
-- หัวใจของไฟล์นี้
--   T6  T7  T16 T17    F4 · ยอดไม่พอ = ปฏิเสธ · ไม่มีการเสกเงิน
--   T13 T14 T15 T18    F8 · เงินหายไปเงียบๆ ไม่ได้ · ledger ต้องสมดุล
--
-- หมายเหตุเรื่อง trigger ที่เป็น DEFERRABLE INITIALLY DEFERRED
--   ปกติมันตรวจตอน COMMIT · ไฟล์นี้ ROLLBACK ทิ้งจึงไม่มี COMMIT
--   จึงใช้ SET CONSTRAINTS ALL IMMEDIATE บังคับให้ตรวจเดี๋ยวนั้น
--   ซึ่งเป็นการตรวจชุดเดียวกับที่ COMMIT จะตรวจ
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

BEGIN;

CREATE TEMP TABLE result (id text, what text, verdict text);

CREATE OR REPLACE FUNCTION t_ok(p_id text, p_what text, p_pass boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO result VALUES (p_id, p_what, CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END) $$;

CREATE OR REPLACE FUNCTION ref_of(p text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to(p,'UTF8')) $$;

CREATE OR REPLACE FUNCTION acct(p_account text, p_id text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT p_account || ':' || p_id $$;

-- ---------------------------------------------------------------------
-- helper · นำ THB เข้าระบบอย่างซื่อสัตย์
-- คู่บัญชีคือ ISSUANCE · ไม่มีทางเพิ่มยอดฝั่งเดียว (F4)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mk_deposit(
  p_account ledger_account, p_id text, p_amount numeric
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_op text := 'opm_' || p_id || '_' || p_amount::text;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,payload,finalized_at)
  VALUES (v_op, 'admin:adm_1','THB_MINT','FINALIZED','{}',now());

  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount,memo) VALUES
   (v_op||'_a', v_op, 1, p_account,  acct(p_account::text, p_id), p_amount,  'ฝากเข้า'),
   (v_op||'_b', v_op, 2, 'ISSUANCE', acct('ISSUANCE','thb'),     -p_amount, 'คู่บัญชี');

  INSERT INTO thb_balance (account, account_id, amount)
  VALUES (p_account, acct(p_account::text, p_id), p_amount)
  ON CONFLICT (account, account_id) DO UPDATE SET amount = thb_balance.amount + p_amount;

  INSERT INTO thb_balance (account, account_id, amount)
  VALUES ('ISSUANCE', acct('ISSUANCE','thb'), -p_amount)
  ON CONFLICT (account, account_id) DO UPDATE SET amount = thb_balance.amount - p_amount;
END $$;

-- ---------------------------------------------------------------------
-- helper · รายการขายที่ ACTIVE แล้ว
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mk_active_listing(
  p_lst text, p_seller text, p_codes text[], p_unit numeric
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE c text; i int := 0;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('opc_'||p_lst,'merchant:'||p_seller,'LISTING_CREATE','FINALIZED',p_lst,'{}',now());

  INSERT INTO listing (id,seller_kind,seller_id,coupon_type_id,unit_price,quantity,status)
  VALUES (p_lst,'MERCHANT',p_seller,'ct_1',p_unit,array_length(p_codes,1),'PENDING');

  FOREACH c IN ARRAY p_codes LOOP
    i := i + 1;
    INSERT INTO listing_item (id,listing_id,coupon_code_id)
    VALUES ('li_'||p_lst||'_'||i, p_lst, c);
    INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
    VALUES ('rsv_'||p_lst||'_'||i,'opc_'||p_lst,'COUPON_UNIT',c,1);
  END LOOP;

  INSERT INTO listing_chain (listing_id,contract_address,chain_listing_id,
                             created_block,created_tx_hash)
  VALUES (p_lst, decode(repeat('aa',20),'hex'),
          ('x'||substr(md5(p_lst),1,8))::bit(32)::bigint, 1000,
          sha256(convert_to(p_lst,'UTF8')));

  UPDATE listing SET status='ACTIVE' WHERE id = p_lst;
END $$;

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id,name,status) VALUES
 ('mch_a','ร้านผู้ขาย','ACTIVE'), ('mch_b','ร้านอื่น','ACTIVE');
INSERT INTO customer (id) VALUES ('cus_rich'),('cus_poor'),('cus_two'),('cus_x');
INSERT INTO signer (address,key_ref) VALUES (decode(repeat('33',20),'hex'),'kms/signer-1');

-- อัตราค่าธรรมเนียม · สองช่วง เพื่อทดสอบว่าอัตราเก่าไม่ถูกเขียนทับย้อนหลัง
INSERT INTO fee_schedule (id,bps,effective_from,note) VALUES
 ('fee_v1', 250, now() - interval '30 days', '2.50 เปอร์เซ็นต์'),
 ('fee_v2', 300, now() + interval '30 days', 'ขึ้นเป็น 3.00 ในอนาคต');

INSERT INTO coupon_type (id,merchant_id,name,face_value,total_supply,status,expires_at)
VALUES ('ct_1','mch_a','คูปอง 100 บาท',100000000000000000000,100,'LIVE',
        now() + interval '180 days');

INSERT INTO coupon_code (id,coupon_type_id,code_hash,code_ref,state,holder_kind,holder_id)
SELECT 'cc_'||g,'ct_1',sha256(('C'||g)::bytea),ref_of('cc_'||g),'HELD','MERCHANT','mch_a'
FROM generate_series(1,20) g;

-- เงินในระบบ · 1000 THB = 1000e18 base units
SELECT mk_deposit('CUSTOMER_THB','cus_rich', 1000000000000000000000);
SELECT mk_deposit('CUSTOMER_THB','cus_two',   200000000000000000000);
SELECT mk_deposit('CUSTOMER_THB','cus_x',     500000000000000000000);
-- cus_poor ไม่มีเงินเลย · ไม่มีแถว thb_balance ด้วย

-- รายการขาย · ราคาต่อใบ 80 THB
SELECT mk_active_listing('lst_a','mch_a',ARRAY['cc_1','cc_2'],  80000000000000000000);
SELECT mk_active_listing('lst_b','mch_a',ARRAY['cc_3'],         80000000000000000000);
SELECT mk_active_listing('lst_c','mch_a',ARRAY['cc_4'],         80000000000000000000);
SELECT mk_active_listing('lst_d','mch_a',ARRAY['cc_5'],         80000000000000000000);
SELECT mk_active_listing('lst_e','mch_a',ARRAY['cc_6'],         80000000000000000000);
SELECT mk_active_listing('lst_f','mch_a',ARRAY['cc_7'],         80000000000000000000);
SELECT mk_active_listing('lst_g','mch_a',ARRAY['cc_8'],         80000000000000000000);
SELECT mk_active_listing('lst_h','mch_a',ARRAY['cc_9'],         80000000000000000000);
-- ราคาที่หารด้วย 10000 ไม่ลงตัว · ใช้ทดสอบการปัดเศษ
SELECT mk_active_listing('lst_odd','mch_a',ARRAY['cc_10'],                      3333);

-- =====================================================================
-- T1 · Idempotency-Key เดิมซ้ำ → ไม่เกิดงานใหม่                RFD 3 R1
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_1','customer:cus_rich','buy-1111-2222-3333',sha256('b'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO idempotency_key (id,scope,key,fingerprint)
  VALUES ('ik_2','customer:cus_rich','buy-1111-2222-3333',sha256('b'))
  ON CONFLICT (scope,key) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T1','ซื้อซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · ซื้อรายการ ACTIVE ของคนอื่น → ยอมรับ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_a','customer:cus_rich','LISTING_BUY','lst_a','{}');
  PERFORM t_ok('T2','ซื้อรายการ ACTIVE ของคนอื่น → ยอมรับ', true);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T2','ซื้อรายการ ACTIVE ของคนอื่น → ยอมรับ', false);
END $$;

-- =====================================================================
-- T3 · ซื้อรายการขายของตัวเอง → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_self','merchant:mch_a','LISTING_BUY','lst_b','{}');
  PERFORM t_ok('T3','ซื้อรายการขายของตัวเอง → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T3','ซื้อรายการขายของตัวเอง → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T4 · ซื้อรายการที่ไม่มีอยู่ → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_ghost','customer:cus_rich','LISTING_BUY','lst_ไม่มีจริง','{}');
  PERFORM t_ok('T4','ซื้อรายการที่ไม่มีอยู่ → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T4','ซื้อรายการที่ไม่มีอยู่ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T5 · ซื้อรายการที่ DELISTED แล้ว → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE listing SET status='DELISTED' WHERE id='lst_c';
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_c','customer:cus_rich','LISTING_BUY','lst_c','{}');
  PERFORM t_ok('T5','ซื้อรายการที่ DELISTED แล้ว → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T5','ซื้อรายการที่ DELISTED แล้ว → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T6 · F4 · ยอด THB ไม่พอ → ถูกปฏิเสธ · ไม่มี autoMint
-- ระบบเดิมเสกเงินขึ้นมาด้วย admin key ตรงจุดนี้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_poor','customer:cus_poor','LISTING_BUY','lst_d','{}');
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_poor','opb_poor','THB_BALANCE',
          acct('CUSTOMER_THB','cus_poor'), 80000000000000000000);
  PERFORM t_ok('T6','F4 · ยอด THB ไม่พอ → ถูกปฏิเสธ ไม่เสกเงินให้', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T6','F4 · ยอด THB ไม่พอ → ถูกปฏิเสธ ไม่เสกเงินให้', true);
END $$;

-- =====================================================================
-- T7 · F4 · หลังถูกปฏิเสธ ไม่มีเงินงอกขึ้นมาและไม่มี ledger เกิดขึ้น
-- =====================================================================
DO $$
DECLARE n_bal int; n_led int;
BEGIN
  SELECT count(*) INTO n_bal FROM thb_balance
   WHERE account_id = acct('CUSTOMER_THB','cus_poor');
  SELECT count(*) INTO n_led FROM ledger_entry
   WHERE account_id = acct('CUSTOMER_THB','cus_poor');
  PERFORM t_ok('T7','F4 · ปฏิเสธแล้วไม่มีแถวยอดและไม่มี ledger งอกขึ้น',
               n_bal = 0 AND n_led = 0);
END $$;

-- =====================================================================
-- T8 · สองคนซื้อใบเดียวกัน → คนที่สองชน uq_listing_inflight
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_a2','customer:cus_two','LISTING_BUY','lst_a','{}');
  PERFORM t_ok('T8','สองคนซื้อใบเดียวกัน → คนที่สองถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T8','สองคนซื้อใบเดียวกัน → คนที่สองถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T9 · ซื้อขณะที่ร้านกดถอดค้างอยู่ → ถูกปฏิเสธ
-- การแข่งเดียวกับ FEAT-09 มองจากฝั่งคนซื้อ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload)
  VALUES ('opd_e','merchant:mch_a','LISTING_DELETE','SUBMITTED','lst_e','{}');
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_e','customer:cus_rich','LISTING_BUY','lst_e','{}');
  PERFORM t_ok('T9','ซื้อขณะมีคำขอถอดค้าง → ถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T9','ซื้อขณะมีคำขอถอดค้าง → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T10 · THB เป็นของบวกกันได้ · จองสองครั้งไม่เกินยอด → ผ่านทั้งคู่
-- ต่างจาก COUPON_UNIT ที่จองซ้อนไม่ได้เลย
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_x1','customer:cus_x','LISTING_BUY','lst_f','{}');
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_x1','opb_x1','THB_BALANCE',acct('CUSTOMER_THB','cus_x'),
          200000000000000000000);
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_x2','customer:cus_x','LISTING_BUY','lst_g','{}');
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_x2','opb_x2','THB_BALANCE',acct('CUSTOMER_THB','cus_x'),
          200000000000000000000);
  SELECT count(*) INTO n FROM reservation
   WHERE subject_type='THB_BALANCE' AND subject_id=acct('CUSTOMER_THB','cus_x')
     AND released_at IS NULL;
  PERFORM t_ok('T10','THB บวกกันได้ · จองสองครั้งไม่เกินยอด → ผ่านทั้งคู่', n = 2);
END $$;

-- =====================================================================
-- T11 · จองครั้งที่สามทำให้รวมเกินยอด → ถูกปฏิเสธ
-- 500 มีอยู่ · จองไป 400 แล้ว · ขออีก 200 ไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('opb_x3','customer:cus_x','LISTING_BUY','lst_h','{}');
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_x3','opb_x3','THB_BALANCE',acct('CUSTOMER_THB','cus_x'),
          200000000000000000000);
  PERFORM t_ok('T11','จองรวมกันเกินยอด → ครั้งที่เกินถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T11','จองรวมกันเกินยอด → ครั้งที่เกินถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T12 · subject_id ของ THB_BALANCE รูปแบบเพี้ยน → ถูกปฏิเสธชัดๆ
-- ตรวจส่วนประกอบก่อน cast · cast ก่อนจะได้ 22P02 ที่บอกอะไรไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_bad','opb_a','THB_BALANCE','ไม่มีโคลอน',1);
  PERFORM t_ok('T12','subject_id ของ THB ไม่มีรูปแบบ → ถูกปฏิเสธด้วย 23514', false);
EXCEPTION
  WHEN check_violation THEN
    PERFORM t_ok('T12','subject_id ของ THB ไม่มีรูปแบบ → ถูกปฏิเสธด้วย 23514', true);
  WHEN invalid_text_representation THEN
    PERFORM t_ok('T12','subject_id ของ THB ไม่มีรูปแบบ → ถูกปฏิเสธด้วย 23514', false);
END $$;

-- =====================================================================
-- T13 · F8 · ledger ที่รวมไม่ได้ศูนย์ → ไม่ผ่าน
-- เงินออกจากคนซื้อแต่ไม่เข้าใครเลย คือสิ่งที่ F8 ปล่อยให้เกิด
-- =====================================================================
DO $$
BEGIN
  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount)
  VALUES ('le_bad','opb_a',1,'CUSTOMER_THB',acct('CUSTOMER_THB','cus_rich'),
          -80000000000000000000);
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM t_ok('T13','F8 · ledger รวมไม่ได้ศูนย์ → ไม่ผ่าน', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T13','F8 · ledger รวมไม่ได้ศูนย์ → ไม่ผ่าน', true);
END $$;

-- =====================================================================
-- T14 · F4 · ตั้งยอดคงเหลือเองโดยไม่มี ledger รองรับ → ไม่ผ่าน
-- นี่คือ autoMintIfNeeded ในรูปของ SQL
-- =====================================================================
DO $$
BEGIN
  INSERT INTO thb_balance (account,account_id,amount)
  VALUES ('CUSTOMER_THB', acct('CUSTOMER_THB','cus_poor'), 999000000000000000000);
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM t_ok('T14','F4 · ตั้งยอดเองโดยไม่มี ledger → ไม่ผ่าน', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T14','F4 · ตั้งยอดเองโดยไม่มี ledger → ไม่ผ่าน', true);
END $$;

-- =====================================================================
-- T15 · F8 · การซื้อที่สมบูรณ์ · สาม entry รวมได้ศูนย์ · ยอดทุกบัญชีตรง
-- =====================================================================
DO $$
DECLARE
  v_total numeric := 160000000000000000000;  -- 80 x 2 ใบ
  v_bps int; v_fee numeric; v_net numeric;
  v_buyer numeric; v_seller numeric; v_plat numeric;
BEGIN
  v_bps := f_fee_bps_at(now());
  v_fee := div(v_total * v_bps, 10000);
  v_net := v_total - v_fee;

  INSERT INTO purchase (id,listing_id,buyer_kind,buyer_id,seller_kind,seller_id,
                        unit_price,quantity,total_price,fee_bps,fee_amount,
                        net_to_seller,operation_id)
  VALUES ('pur_a','lst_a','CUSTOMER','cus_rich','MERCHANT','mch_a',
          80000000000000000000,2,v_total,v_bps,v_fee,v_net,'opb_a');

  INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
  VALUES ('rsv_a_thb','opb_a','THB_BALANCE',acct('CUSTOMER_THB','cus_rich'),v_total);

  -- chain บอกว่า executePurchase สำเร็จ
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp,operation_id)
  VALUES ('ce_buy',2000,decode(repeat('bb',32),'hex'),decode(repeat('c1',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now(),'opb_a');

  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount,memo) VALUES
   ('le_a1','opb_a',1,'CUSTOMER_THB',acct('CUSTOMER_THB','cus_rich'),-v_total,'จ่ายค่าคูปอง'),
   ('le_a2','opb_a',2,'MERCHANT_THB',acct('MERCHANT_THB','mch_a'),   v_net,  'รับเงินสุทธิ'),
   ('le_a3','opb_a',3,'PLATFORM_THB',acct('PLATFORM_THB','plat'),    v_fee,  'ค่าธรรมเนียม');

  UPDATE thb_balance SET amount = amount - v_total
   WHERE account='CUSTOMER_THB' AND account_id=acct('CUSTOMER_THB','cus_rich');
  INSERT INTO thb_balance (account,account_id,amount)
  VALUES ('MERCHANT_THB',acct('MERCHANT_THB','mch_a'),v_net)
  ON CONFLICT (account,account_id) DO UPDATE SET amount=thb_balance.amount+v_net;
  INSERT INTO thb_balance (account,account_id,amount)
  VALUES ('PLATFORM_THB',acct('PLATFORM_THB','plat'),v_fee)
  ON CONFLICT (account,account_id) DO UPDATE SET amount=thb_balance.amount+v_fee;

  UPDATE operation SET status='FINALIZED', finalized_at=now() WHERE id='opb_a';
  UPDATE purchase SET status='SETTLED', settled_at=now() WHERE id='pur_a';
  UPDATE listing SET status='SOLD' WHERE id='lst_a';
  UPDATE reservation SET released_at=now()
   WHERE operation_id IN ('opb_a','opc_lst_a') AND released_at IS NULL;

  INSERT INTO coupon_holding (coupon_code_id,holder_kind,holder_id,chain_event_id) VALUES
   ('cc_1','CUSTOMER','cus_rich','ce_buy'),
   ('cc_2','CUSTOMER','cus_rich','ce_buy');
  UPDATE coupon_code SET holder_kind='CUSTOMER', holder_id='cus_rich'
   WHERE id IN ('cc_1','cc_2');

  SET CONSTRAINTS ALL IMMEDIATE;

  SELECT amount INTO v_buyer  FROM thb_balance WHERE account_id=acct('CUSTOMER_THB','cus_rich');
  SELECT amount INTO v_seller FROM thb_balance WHERE account_id=acct('MERCHANT_THB','mch_a');
  SELECT amount INTO v_plat   FROM thb_balance WHERE account_id=acct('PLATFORM_THB','plat');

  PERFORM t_ok('T15','F8 · ซื้อสำเร็จ · เงินถึงผู้ขายและ platform จริง',
               v_buyer  = 1000000000000000000000 - v_total
           AND v_seller = v_net
           AND v_plat   = v_fee
           AND v_net + v_fee = v_total);
END $$;

-- =====================================================================
-- T16 · ผลรวม ledger ทั้งตาราง = ศูนย์
-- เงินในระบบไม่งอกและไม่หาย ไม่ว่าจะเกิดอะไรขึ้นก่อนหน้านี้
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  SELECT coalesce(sum(amount),0) INTO v FROM ledger_entry;
  PERFORM t_ok('T16','ผลรวม ledger ทั้งตาราง = ศูนย์', v = 0);
END $$;

-- =====================================================================
-- T17 · F4 · ค่าติดลบของ ISSUANCE = THB ที่หมุนอยู่ในระบบทั้งหมด
-- ถ้ามีการเสกเงิน สองข้างนี้จะไม่เท่ากัน
-- =====================================================================
DO $$
DECLARE v_iss numeric; v_rest numeric;
BEGIN
  SELECT coalesce(sum(amount),0) INTO v_iss  FROM thb_balance WHERE account='ISSUANCE';
  SELECT coalesce(sum(amount),0) INTO v_rest FROM thb_balance WHERE account<>'ISSUANCE';
  PERFORM t_ok('T17','F4 · ลบ ISSUANCE = ผลรวมบัญชีอื่นทั้งหมด', -v_iss = v_rest);
END $$;

-- =====================================================================
-- T18 · ledger ที่มี amount เป็นศูนย์ → ถูกปฏิเสธ
-- แถวที่ไม่เคลื่อนอะไรไม่ควรมีอยู่
-- =====================================================================
DO $$
BEGIN
  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount)
  VALUES ('le_zero','opb_a',9,'CUSTOMER_THB',acct('CUSTOMER_THB','cus_rich'),0);
  PERFORM t_ok('T18','ledger amount = 0 → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T18','ledger amount = 0 → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T19 · fee บวก net ไม่เท่ากับ total → ถูกปฏิเสธ
-- หนึ่งหน่วยเล็กสุดที่หายไปก็ไม่ยอม
-- =====================================================================
DO $$
BEGIN
  INSERT INTO purchase (id,listing_id,buyer_kind,buyer_id,seller_kind,seller_id,
                        unit_price,quantity,total_price,fee_bps,fee_amount,
                        net_to_seller,operation_id)
  VALUES ('pur_bad1','lst_f','CUSTOMER','cus_x','MERCHANT','mch_a',
          80000000000000000000,1,80000000000000000000,250,
          2000000000000000000, 77999999999999999999, 'opb_x1');
  PERFORM t_ok('T19','fee บวก net ขาดไปหนึ่งหน่วย → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T19','fee บวก net ขาดไปหนึ่งหน่วย → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T20 · total ไม่เท่ากับ unit_price คูณ quantity → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO purchase (id,listing_id,buyer_kind,buyer_id,seller_kind,seller_id,
                        unit_price,quantity,total_price,fee_bps,fee_amount,
                        net_to_seller,operation_id)
  VALUES ('pur_bad2','lst_f','CUSTOMER','cus_x','MERCHANT','mch_a',
          80000000000000000000,2,80000000000000000000,0,0,
          80000000000000000000,'opb_x1');
  PERFORM t_ok('T20','total ไม่เท่ากับ unit คูณ qty → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T20','total ไม่เท่ากับ unit คูณ qty → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T21 · fee ที่ไม่ตรงกับ bps → ถูกปฏิเสธ แม้ fee บวก net จะเท่ากับ total
-- ตัวเลขต้องถูกทั้งสามทาง ไม่ใช่แค่สองทาง
-- =====================================================================
DO $$
BEGIN
  INSERT INTO purchase (id,listing_id,buyer_kind,buyer_id,seller_kind,seller_id,
                        unit_price,quantity,total_price,fee_bps,fee_amount,
                        net_to_seller,operation_id)
  VALUES ('pur_bad3','lst_f','CUSTOMER','cus_x','MERCHANT','mch_a',
          80000000000000000000,1,80000000000000000000,250,
          8000000000000000000, 72000000000000000000,'opb_x1');
  PERFORM t_ok('T21','fee ไม่ตรงกับ bps → ถูกปฏิเสธ แม้ยอดรวมจะลงตัว', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T21','fee ไม่ตรงกับ bps → ถูกปฏิเสธ แม้ยอดรวมจะลงตัว', true);
END $$;

-- =====================================================================
-- T22 · ปัดเศษลง · เศษที่ปัดตกเป็นของผู้ขาย ไม่ใช่ของ platform
-- 3333 x 250 / 10000 = 83.325 → fee 83 · net 3250
-- =====================================================================
DO $$
DECLARE v_fee numeric; v_net numeric;
BEGIN
  INSERT INTO purchase (id,listing_id,buyer_kind,buyer_id,seller_kind,seller_id,
                        unit_price,quantity,total_price,fee_bps,fee_amount,
                        net_to_seller,operation_id)
  VALUES ('pur_odd','lst_odd','CUSTOMER','cus_two','MERCHANT','mch_a',
          3333,1,3333,250,div(3333*250,10000),3333-div(3333*250,10000),'opb_x1');
  SELECT fee_amount, net_to_seller INTO v_fee, v_net FROM purchase WHERE id='pur_odd';
  PERFORM t_ok('T22','ปัดเศษลง · เศษตกเป็นของผู้ขาย (fee 83 · net 3250)',
               v_fee = 83 AND v_net = 3250 AND v_fee + v_net = 3333);
END $$;

-- =====================================================================
-- T23 · เปลี่ยนอัตราค่าธรรมเนียมในอนาคต ไม่กระทบยอดที่คิดไว้แล้ว
-- f_fee_bps_at ตอบตามเวลาที่ถาม · purchase บันทึก bps ที่ใช้จริงไว้
-- =====================================================================
DO $$
DECLARE v_now int; v_future int; v_saved int;
BEGIN
  v_now    := f_fee_bps_at(now());
  v_future := f_fee_bps_at(now() + interval '60 days');
  SELECT fee_bps INTO v_saved FROM purchase WHERE id='pur_a';
  PERFORM t_ok('T23','อัตรา fee อิงเวลา · การซื้อเก่าเก็บอัตราของตัวเองไว้',
               v_now = 250 AND v_future = 300 AND v_saved = 250);
END $$;

-- =====================================================================
-- T24 · แก้ราคารายการที่ขึ้นขายแล้ว → ถูกปฏิเสธ
-- คนซื้อเห็นราคาหนึ่งแล้วกดซื้อ · ราคาต้องไม่ขยับใต้มือ
-- =====================================================================
DO $$
BEGIN
  UPDATE listing SET unit_price = 10 WHERE id='lst_f';
  PERFORM t_ok('T24','แก้ราคารายการที่ ACTIVE → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T24','แก้ราคารายการที่ ACTIVE → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T25 · ซื้อ = สอง step เรียงกัน approveTHB → executePurchase
-- =====================================================================
DO $$
DECLARE v text[];
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name) VALUES
   ('st_f1','opb_x1',1,'approveTHB'),
   ('st_f2','opb_x1',2,'executePurchase');
  SELECT array_agg(name ORDER BY step_index) INTO v
    FROM operation_step WHERE operation_id='opb_x1';
  PERFORM t_ok('T25','ซื้อ = 2 step เรียงกัน approveTHB → executePurchase',
               v = ARRAY['approveTHB','executePurchase']);
END $$;

-- =====================================================================
-- T26 · ยิง executePurchase ก่อน approveTHB จบ → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE operation_step SET status='SUBMITTED', raw_tx='\x02', submitted_at=now()
   WHERE id='st_f2';
  PERFORM t_ok('T26','ยิง executePurchase ก่อน approveTHB จบ → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T26','ยิง executePurchase ก่อน approveTHB จบ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T27 · R2 · SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name,status)
  VALUES ('st_nr','opb_x2',1,'approveTHB','SUBMITTED');
  PERFORM t_ok('T27','R2 · SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T27','R2 · SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T28 · คูปองย้ายมือได้เฉพาะเมื่อมี chain_event รองรับ
-- ไม่มี event = ไม่มีการย้าย · projection ต้องสืบกลับได้ทุกแถว
-- =====================================================================
DO $$
BEGIN
  INSERT INTO coupon_holding (coupon_code_id,holder_kind,holder_id,chain_event_id)
  VALUES ('cc_11','CUSTOMER','cus_two','ce_ไม่มีจริง');
  PERFORM t_ok('T28','ย้ายคูปองโดยอ้าง event ที่ไม่มี → ถูกปฏิเสธ', false);
EXCEPTION WHEN foreign_key_violation THEN
  PERFORM t_ok('T28','ย้ายคูปองโดยอ้าง event ที่ไม่มี → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T29 · ซื้อสำเร็จแล้ว · คูปองอยู่กับคนซื้อ · listing เป็น SOLD
-- =====================================================================
DO $$
DECLARE n int; v listing_status;
BEGIN
  SELECT count(*) INTO n FROM coupon_holding
   WHERE holder_kind='CUSTOMER' AND holder_id='cus_rich';
  SELECT status INTO v FROM listing WHERE id='lst_a';
  PERFORM t_ok('T29','ซื้อสำเร็จ · คูปอง 2 ใบอยู่กับคนซื้อ · listing SOLD',
               n = 2 AND v = 'SOLD');
END $$;

-- =====================================================================
-- T30 · รายการเดียวขายซ้ำสองครั้ง → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO purchase (id,listing_id,buyer_kind,buyer_id,seller_kind,seller_id,
                        unit_price,quantity,total_price,fee_bps,fee_amount,
                        net_to_seller,operation_id)
  VALUES ('pur_dup','lst_a','CUSTOMER','cus_two','MERCHANT','mch_a',
          80000000000000000000,2,160000000000000000000,250,
          4000000000000000000,156000000000000000000,'opb_x1');
  PERFORM t_ok('T30','ขายรายการเดิมซ้ำ → ชน uq_purchase_listing', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T30','ขายรายการเดิมซ้ำ → ชน uq_purchase_listing', true);
END $$;

-- =====================================================================
-- T31 · tx revert · ปล่อยเงินที่จองคืน · ยอดคงเหลือกลับเป็นเดิม
-- เงินที่กันไว้ไม่เคยถูกย้าย จึงไม่ต้องย้ายกลับ แค่ปล่อยการจอง
-- =====================================================================
DO $$
DECLARE v_before numeric; v_after numeric; v_avail numeric;
BEGIN
  SELECT amount INTO v_before FROM thb_balance
   WHERE account_id = acct('CUSTOMER_THB','cus_x');

  UPDATE operation SET status='CHAIN_REVERTED',
         error_note='executePurchase revert' WHERE id='opb_x2';
  UPDATE reservation SET released_at=now() WHERE id='rsv_x2';

  SELECT amount INTO v_after FROM thb_balance
   WHERE account_id = acct('CUSTOMER_THB','cus_x');
  v_avail := f_available_thb('CUSTOMER_THB', acct('CUSTOMER_THB','cus_x'));

  PERFORM t_ok('T31','tx revert · ปล่อยจองคืน · ยอดไม่เปลี่ยน ยอดใช้ได้เพิ่ม',
               v_before = v_after AND v_avail = 300000000000000000000);
END $$;

-- =====================================================================
-- T32 · ปล่อยจองก่อน operation จบ → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE reservation SET released_at=now() WHERE id='rsv_x1';
  PERFORM t_ok('T32','ปล่อยจองขณะ operation ยัง PENDING → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T32','ปล่อยจองขณะ operation ยัง PENDING → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T33 · บัญชีที่ไม่ใช่ ISSUANCE ติดลบไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO thb_balance (account,account_id,amount)
  VALUES ('CUSTOMER_THB',acct('CUSTOMER_THB','cus_neg'),-1);
  PERFORM t_ok('T33','ยอดลูกค้าติดลบ → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T33','ยอดลูกค้าติดลบ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T34 · outbox topic ต้องมีเวอร์ชันลงท้าย
-- =====================================================================
DO $$
BEGIN
  INSERT INTO outbox (id,operation_id,topic,payload)
  VALUES ('obx_bad','opb_a','listing.buy','{}');
  PERFORM t_ok('T34','outbox topic ไม่มี .vN → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T34','outbox topic ไม่มี .vN → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T35 · อ่าน log ช่วงเดิมซ้ำได้                              RFD 5 D2
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_r1',2001,decode(repeat('bb',32),'hex'),decode(repeat('d1',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_r2',2001,decode(repeat('bb',32),'hex'),decode(repeat('d1',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T35','อ่าน log ช่วงเดิมซ้ำ → chain_event ไม่เกิดแถวซ้ำ', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T36 · ข้อสุดท้าย · ตรวจความสมดุลทั้งระบบอีกครั้งหลังทุกอย่างเกิดขึ้น
-- รวม ledger = 0 · ทุกยอดคงเหลือ = ผลรวม ledger ของบัญชีนั้น
-- =====================================================================
DO $$
DECLARE v_sum numeric; v_mismatch int;
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT coalesce(sum(amount),0) INTO v_sum FROM ledger_entry;
  SELECT count(*) INTO v_mismatch FROM thb_balance b
   WHERE b.amount <> coalesce((SELECT sum(amount) FROM ledger_entry l
                                WHERE l.account=b.account AND l.account_id=b.account_id), 0);
  PERFORM t_ok('T36','ปิดท้าย · ledger รวม 0 และทุกยอดตรงกับ ledger ของตัวเอง',
               v_sum = 0 AND v_mismatch = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

ROLLBACK;
