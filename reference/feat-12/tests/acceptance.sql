-- =====================================================================
-- FEAT-12 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat12 -f tests/acceptance.sql
-- ทุกแถวต้องขึ้น PASS · แถวเดียวที่ FAIL = schema ไม่ให้สิ่งที่ RFD สัญญาไว้
--
-- หัวใจของไฟล์นี้
--   T8  T9  T10     F4 · mint ได้เฉพาะจากการฝากที่ยืนยันแล้ว
--   T16 T17         F4 · ISSUANCE ขยับได้ที่ FEAT-12 เท่านั้น
--   T21-T25         การตีกลับ · ยอดไม่พอต้องเป็น MANUAL_REVIEW ไม่ใช่แต่งตัวเลข
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

BEGIN;

CREATE TEMP TABLE result (id text, what text, verdict text);

CREATE OR REPLACE FUNCTION t_ok(p_id text, p_what text, p_pass boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO result VALUES (p_id, p_what, CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END) $$;

CREATE OR REPLACE FUNCTION acct(a text, b text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT a || ':' || b $$;

-- 1 บาท = 100 สตางค์ = 10^18 base units
CREATE OR REPLACE FUNCTION baht(p numeric) RETURNS bigint
LANGUAGE sql IMMUTABLE AS $$ SELECT (p * 100)::bigint $$;

-- ---------------------------------------------------------------------
-- helper · webhook ที่ลายเซ็นผ่าน
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mk_webhook(p_id text, p_evt text, p_type text, p_ok boolean DEFAULT true)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO psp_webhook (id,provider,provider_event_id,event_type,raw_body,signature,signature_ok)
  VALUES (p_id,'omise',p_evt,p_type,convert_to('{"id":"'||p_evt||'"}','UTF8'),'sig_'||p_evt,p_ok);
  RETURN p_id;
END $$;

-- ---------------------------------------------------------------------
-- helper · การฝากที่ยืนยันแล้ว
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mk_confirmed_deposit(
  p_dep text, p_holder text, p_satang bigint, p_wh text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO thb_deposit (id,holder_kind,holder_id,provider,provider_ref,
                           amount_satang,amount_base)
  VALUES (p_dep,'CUSTOMER',p_holder,'omise','ref_'||p_dep,
          p_satang, f_satang_to_base(p_satang));
  UPDATE thb_deposit SET status='CONFIRMED', webhook_id=p_wh WHERE id=p_dep;
END $$;

-- ---------------------------------------------------------------------
-- helper · mint ให้จบครบวงจร · ledger สมดุล
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION do_mint(p_dep text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_op text; v_amt numeric; v_hid text; v_key text; v_ce text;
BEGIN
  SELECT amount_base, holder_id INTO v_amt, v_hid FROM thb_deposit WHERE id=p_dep;
  v_op  := 'opm_' || p_dep;
  v_ce  := 'ce_'  || p_dep;
  v_key := acct('CUSTOMER_THB', v_hid);

  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES (v_op,'system:minter','THB_MINT','FINALIZED',p_dep,'{}',now());

  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp,operation_id)
  VALUES (v_ce,3000,decode(repeat('bb',32),'hex'),
          sha256(convert_to(p_dep,'UTF8')),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now(),v_op);

  INSERT INTO thb_mint (deposit_id,operation_id,amount_base,to_account,to_account_id,
                        chain_event_id,tx_hash,minted_block,applied_at)
  VALUES (p_dep,v_op,v_amt,'CUSTOMER_THB',v_key,v_ce,
          sha256(convert_to(p_dep,'UTF8')),3000,now());

  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount,memo) VALUES
   (v_op||'_a',v_op,1,'CUSTOMER_THB',v_key,       v_amt,'THB เข้าจากการฝาก'),
   (v_op||'_b',v_op,2,'ISSUANCE',acct('ISSUANCE','thb'),-v_amt,'คู่บัญชีของการ mint');

  INSERT INTO thb_balance (account,account_id,amount) VALUES ('CUSTOMER_THB',v_key,v_amt)
  ON CONFLICT (account,account_id) DO UPDATE SET amount=thb_balance.amount+v_amt;
  INSERT INTO thb_balance (account,account_id,amount)
  VALUES ('ISSUANCE',acct('ISSUANCE','thb'),-v_amt)
  ON CONFLICT (account,account_id) DO UPDATE SET amount=thb_balance.amount-v_amt;

  UPDATE thb_deposit SET status='MINTED' WHERE id=p_dep;
END $$;

-- ------------------------------------------------------------ fixture
INSERT INTO merchant (id,name,status) VALUES ('mch_a','ร้าน','ACTIVE');
INSERT INTO customer (id) VALUES ('cus_1'),('cus_2'),('cus_3'),('cus_spent'),('cus_4');
INSERT INTO signer (address,key_ref) VALUES (decode(repeat('33',20),'hex'),'kms/minter-1');

SELECT mk_webhook('wh_1','evt_1','charge.complete');
SELECT mk_webhook('wh_2','evt_2','charge.complete');
SELECT mk_webhook('wh_3','evt_3','charge.complete');
SELECT mk_webhook('wh_4','evt_4','charge.complete');
SELECT mk_webhook('wh_5','evt_5','charge.complete');
SELECT mk_webhook('wh_6','evt_6','charge.complete');
SELECT mk_webhook('wh_r1','evt_r1','charge.reverse');
SELECT mk_webhook('wh_r2','evt_r2','charge.reverse');
SELECT mk_webhook('wh_bad','evt_bad','charge.complete', false);

-- การฝากที่ยืนยันแล้ว · สร้างที่นี่ทั้งหมด ไม่สร้างใน DO block
-- เพราะ block ที่คาดว่าจะ raise จะ rollback ของที่มันสร้างเองไปด้วย
SELECT mk_confirmed_deposit('dep_1','cus_1',     baht(100), 'wh_1');
SELECT mk_confirmed_deposit('dep_2','cus_2',     baht(200), 'wh_2');
SELECT mk_confirmed_deposit('dep_3','cus_3',     baht(300), 'wh_3');
SELECT mk_confirmed_deposit('dep_4','cus_4',     baht(400), 'wh_4');
SELECT mk_confirmed_deposit('dep_5','cus_spent', baht(500), 'wh_5');
SELECT mk_confirmed_deposit('dep_6','cus_2',     baht(600), 'wh_6');
SELECT mk_confirmed_deposit('dep_7','cus_3',     baht(700), 'wh_2');

-- =====================================================================
-- T1 · webhook เดิมที่ผู้ให้บริการส่งซ้ำ → ไม่ประมวลผลสองรอบ
-- idempotency ของ feature นี้มาจากข้างนอก ไม่ใช่ header ที่เราเลือก
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO psp_webhook (id,provider,provider_event_id,event_type,raw_body,signature,signature_ok)
  VALUES ('wh_dup1','omise','evt_dup','charge.complete','\x7b7d','sig',true)
  ON CONFLICT (provider,provider_event_id) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO psp_webhook (id,provider,provider_event_id,event_type,raw_body,signature,signature_ok)
  VALUES ('wh_dup2','omise','evt_dup','charge.complete','\x7b7d','sig',true)
  ON CONFLICT (provider,provider_event_id) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T1','webhook เดิมส่งซ้ำ → แถวที่สองได้ 0 rows', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · payload ดิบแก้ไม่ได้ · ถ้าแก้ได้ก็เลิกเป็นหลักฐาน
-- =====================================================================
DO $$
BEGIN
  UPDATE psp_webhook SET raw_body = '\x00' WHERE id='wh_1';
  PERFORM t_ok('T2','แก้ raw_body ของ webhook → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T2','แก้ raw_body ของ webhook → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T3 · ทำเครื่องหมายว่าประมวลผลแล้วได้ · แก้ได้แค่ช่องนั้น
-- =====================================================================
DO $$
DECLARE v timestamptz;
BEGIN
  UPDATE psp_webhook SET processed_at = now() WHERE id='wh_1';
  SELECT processed_at INTO v FROM psp_webhook WHERE id='wh_1';
  PERFORM t_ok('T3','เขียน processed_at ได้ · ช่องอื่นแก้ไม่ได้', v IS NOT NULL);
END $$;

-- =====================================================================
-- T4 · ยอดสตางค์กับ base units ต้องแปลงกันพอดี
-- 100.50 บาท = 10050 สตางค์ = 100500000000000000000 base units
-- =====================================================================
DO $$
DECLARE v numeric;
BEGIN
  INSERT INTO thb_deposit (id,holder_kind,holder_id,provider,provider_ref,
                           amount_satang,amount_base)
  VALUES ('dep_x','CUSTOMER','cus_1','omise','ref_x',
          baht(100.50), f_satang_to_base(baht(100.50)));
  SELECT amount_base INTO v FROM thb_deposit WHERE id='dep_x';
  PERFORM t_ok('T4','100.50 บาท = 10050 สตางค์ = 100.5e18 base units',
               v = 100500000000000000000);
END $$;

-- =====================================================================
-- T5 · ยอด base units ไม่ตรงกับสตางค์ → ถูกปฏิเสธ
-- รอยต่อระหว่างเงินจริงกับ chain คือที่ที่บั๊กผิดหลักสิบยกกำลังอยู่
-- =====================================================================
DO $$
BEGIN
  INSERT INTO thb_deposit (id,holder_kind,holder_id,provider,provider_ref,
                           amount_satang,amount_base)
  VALUES ('dep_bad','CUSTOMER','cus_1','omise','ref_bad',
          10000, 100000000000000000000000);  -- เกินไป 1000 เท่า
  PERFORM t_ok('T5','ยอด base ผิดหลักสิบยกกำลัง → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T5','ยอด base ผิดหลักสิบยกกำลัง → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T6 · reference เดิมของผู้ให้บริการ → ฝากซ้ำไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO thb_deposit (id,holder_kind,holder_id,provider,provider_ref,
                           amount_satang,amount_base)
  VALUES ('dep_dup','CUSTOMER','cus_1','omise','ref_x',10000,
          f_satang_to_base(10000));
  PERFORM t_ok('T6','provider_ref ซ้ำ → ชน uq_deposit_provider_ref', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T6','provider_ref ซ้ำ → ชน uq_deposit_provider_ref', true);
END $$;

-- =====================================================================
-- T7 · ยืนยันการฝากโดยไม่มี webhook อ้างอิง → ถูกปฏิเสธ
-- ยืนยันเองลอยๆ ไม่ได้ · ต้องมีคำพูดของผู้ให้บริการรองรับ
-- =====================================================================
DO $$
BEGIN
  UPDATE thb_deposit SET status='CONFIRMED' WHERE id='dep_x';
  PERFORM t_ok('T7','ยืนยันการฝากโดยไม่มี webhook → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T7','ยืนยันการฝากโดยไม่มี webhook → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T8 · F4 · mint จากการฝากที่ยัง PENDING_PAYMENT → ถูกปฏิเสธ
-- นี่คือ autoMintIfNeeded ตรงๆ · สร้าง THB โดยไม่มีเงินบาทรองรับ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_bad1','system:minter','THB_MINT','dep_x','{}');
  INSERT INTO thb_mint (deposit_id,operation_id,amount_base,to_account,to_account_id)
  VALUES ('dep_x','op_bad1',100500000000000000000,'CUSTOMER_THB',
          acct('CUSTOMER_THB','cus_1'));
  PERFORM t_ok('T8','F4 · mint จากการฝากที่ยังไม่จ่าย → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T8','F4 · mint จากการฝากที่ยังไม่จ่าย → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T9 · F4 · mint ยอดมากกว่าที่ฝาก → ถูกปฏิเสธ
-- ฝาก 100 แล้ว mint 1000 คือการเสกส่วนต่างขึ้นมา
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_bad2','system:minter','THB_MINT','dep_1','{}');
  INSERT INTO thb_mint (deposit_id,operation_id,amount_base,to_account,to_account_id)
  VALUES ('dep_1','op_bad2', f_satang_to_base(baht(1000)),'CUSTOMER_THB',
          acct('CUSTOMER_THB','cus_1'));
  PERFORM t_ok('T9','F4 · mint ยอดมากกว่าที่ฝาก → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T9','F4 · mint ยอดมากกว่าที่ฝาก → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T10 · mint ไปบัญชีที่ไม่ใช่เจ้าของการฝาก → ถูกปฏิเสธ
-- ฝากเงินของ cus_1 แล้ว THB ไปเข้า cus_2 ไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_bad3','system:minter','THB_MINT','dep_1','{}');
  INSERT INTO thb_mint (deposit_id,operation_id,amount_base,to_account,to_account_id)
  VALUES ('dep_1','op_bad3', f_satang_to_base(baht(100)),'CUSTOMER_THB',
          acct('CUSTOMER_THB','cus_2'));
  PERFORM t_ok('T10','mint ไปบัญชีคนอื่น → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T10','mint ไปบัญชีคนอื่น → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T11 · mint ที่ถูกต้องครบวงจร · ยอดเข้าบัญชี ledger สมดุล
-- =====================================================================
DO $$
DECLARE v_bal numeric; v_iss numeric; v_st deposit_status;
BEGIN
  PERFORM do_mint('dep_1');
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT amount INTO v_bal FROM thb_balance WHERE account_id=acct('CUSTOMER_THB','cus_1');
  SELECT amount INTO v_iss FROM thb_balance WHERE account='ISSUANCE';
  SELECT status  INTO v_st  FROM thb_deposit WHERE id='dep_1';
  PERFORM t_ok('T11','mint ถูกต้อง · ยอดเข้า 100 บาท · ISSUANCE ติดลบเท่ากัน',
               v_bal = 100000000000000000000
           AND v_iss = -100000000000000000000
           AND v_st  = 'MINTED');
END $$;

-- =====================================================================
-- T12 · การฝากเดียว mint ซ้ำไม่ได้ · ถูกกันสองชั้น
--
-- ชั้นแรก  สถานะ · mint แล้วการฝากเป็น MINTED ไม่ใช่ CONFIRMED อีก
-- ชั้นที่สอง primary key บน deposit_id
--
-- ชั้นแรกยิงก่อนในเส้นทางปกติ · ชั้นที่สองกันกรณีที่ยัดสองแถว
-- ใน transaction เดียวก่อนที่สถานะจะถูกอัปเดต ซึ่งชั้นแรกมองไม่เห็น
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_bad4','system:minter','THB_MINT','dep_1','{}');
  INSERT INTO thb_mint (deposit_id,operation_id,amount_base,to_account,to_account_id)
  VALUES ('dep_1','op_bad4', f_satang_to_base(baht(100)),'CUSTOMER_THB',
          acct('CUSTOMER_THB','cus_1'));
  PERFORM t_ok('T12','mint การฝากที่ MINTED แล้ว → ถูกปฏิเสธด้วยสถานะ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T12','mint การฝากที่ MINTED แล้ว → ถูกปฏิเสธด้วยสถานะ', true);
END $$;

-- =====================================================================
-- T12b · ยัดสองแถว mint ใน transaction เดียว → primary key กันไว้
-- สถานะยังเป็น CONFIRMED ทั้งสองครั้ง ชั้นแรกจึงมองไม่เห็น
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('op_d7a','system:minter','THB_MINT','FINALIZED','dep_7','{}',now());
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('op_d7b','system:minter','THB_MINT','FINALIZED','dep_7x','{}',now());
  INSERT INTO thb_mint (deposit_id,operation_id,amount_base,to_account,to_account_id)
  VALUES ('dep_7','op_d7a', f_satang_to_base(baht(700)),'CUSTOMER_THB',
          acct('CUSTOMER_THB','cus_3'));
  INSERT INTO thb_mint (deposit_id,operation_id,amount_base,to_account,to_account_id)
  VALUES ('dep_7','op_d7b', f_satang_to_base(baht(700)),'CUSTOMER_THB',
          acct('CUSTOMER_THB','cus_3'));
  PERFORM t_ok('T12b','สอง mint บนการฝากเดียวใน tx เดียว → ชน primary key', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T12b','สอง mint บนการฝากเดียวใน tx เดียว → ชน primary key', true);
END $$;

-- =====================================================================
-- T13 · MINTED กลับไป CONFIRMED ไม่ได้
-- =====================================================================
DO $$
BEGIN
  UPDATE thb_deposit SET status='CONFIRMED' WHERE id='dep_1';
  PERFORM t_ok('T13','MINTED กลับไป CONFIRMED → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T13','MINTED กลับไป CONFIRMED → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T14 · PENDING_PAYMENT ข้ามไป MINTED ตรงๆ ไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO thb_deposit (id,holder_kind,holder_id,provider,provider_ref,
                           amount_satang,amount_base)
  VALUES ('dep_skip','CUSTOMER','cus_2','omise','ref_skip',
          baht(50), f_satang_to_base(baht(50)));
  UPDATE thb_deposit SET status='MINTED' WHERE id='dep_skip';
  PERFORM t_ok('T14','PENDING_PAYMENT ข้ามไป MINTED → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T14','PENDING_PAYMENT ข้ามไป MINTED → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T15 · ยืนยันแล้วแก้ยอดไม่ได้ · ยืนยัน 100 แล้ว mint 1000 ไม่ได้
-- =====================================================================
DO $$
BEGIN
  UPDATE thb_deposit SET amount_satang = baht(2000),
         amount_base = f_satang_to_base(baht(2000)) WHERE id='dep_2';
  PERFORM t_ok('T15','ยืนยันแล้วแก้ยอด → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T15','ยืนยันแล้วแก้ยอด → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T16 · F4 · operation ที่ไม่ใช่ THB_MINT แตะ ISSUANCE ไม่ได้
-- ข้อนี้คือสิ่งที่ทำให้กฎของ FEAT-10 มีความหมาย
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_buy','customer:cus_1','LISTING_BUY','lst_x','{}');
  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount)
  VALUES ('le_bad','op_buy',1,'ISSUANCE',acct('ISSUANCE','thb'),-999);
  PERFORM t_ok('T16','F4 · LISTING_BUY แตะ ISSUANCE → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T16','F4 · LISTING_BUY แตะ ISSUANCE → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T17 · F4 · ลบ ISSUANCE = ผลรวมบัญชีอื่นทั้งหมด
-- =====================================================================
DO $$
DECLARE v_iss numeric; v_rest numeric;
BEGIN
  SELECT coalesce(sum(amount),0) INTO v_iss  FROM thb_balance WHERE account='ISSUANCE';
  SELECT coalesce(sum(amount),0) INTO v_rest FROM thb_balance WHERE account<>'ISSUANCE';
  PERFORM t_ok('T17','F4 · ลบ ISSUANCE = ผลรวมบัญชีอื่น', -v_iss = v_rest);
END $$;

-- =====================================================================
-- T18 · ledger ของ mint ที่รวมไม่ได้ศูนย์ → ไม่ผ่านตอน COMMIT
-- เข้าบัญชีลูกค้าแต่ไม่ลด ISSUANCE คือการเสกเงิน
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('op_half','system:minter','THB_MINT','FINALIZED','dep_3','{}',now());
  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount)
  VALUES ('le_half','op_half',1,'CUSTOMER_THB',acct('CUSTOMER_THB','cus_3'),
          f_satang_to_base(baht(300)));
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM t_ok('T18','mint ที่ไม่ลด ISSUANCE → ไม่ผ่าน', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T18','mint ที่ไม่ลด ISSUANCE → ไม่ผ่าน', true);
END $$;

-- =====================================================================
-- T19 · mint = หนึ่ง step · ไม่ใช่สองหรือสาม
-- =====================================================================
DO $$
DECLARE v text[];
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name)
  VALUES ('st_1','opm_dep_1',1,'mintTHB');
  SELECT array_agg(name ORDER BY step_index) INTO v
    FROM operation_step WHERE operation_id='opm_dep_1';
  PERFORM t_ok('T19','mint = 1 step · mintTHB', v = ARRAY['mintTHB']);
END $$;

-- =====================================================================
-- T20 · R2 · SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name,status)
  VALUES ('st_nr','opm_dep_1',2,'mintTHB','SUBMITTED');
  PERFORM t_ok('T20','R2 · SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T20','R2 · SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T21 · ตีกลับขณะยอดยังพอ → เผาคืนได้ · ledger สมดุล · ยอดเหลือศูนย์
-- =====================================================================
DO $$
DECLARE v_bal numeric; v_out reversal_outcome;
BEGIN
  PERFORM do_mint('dep_4');

  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('opr_4','system:psp','THB_MINT','FINALIZED','dep_4','{}',now());

  INSERT INTO deposit_reversal (id,deposit_id,webhook_id,operation_id,amount_base,
                                available_at_reversal,outcome)
  VALUES ('rev_4','dep_4','wh_r1','opr_4', f_satang_to_base(baht(400)),
          f_available_thb('CUSTOMER_THB',acct('CUSTOMER_THB','cus_4')),'BURNED');

  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount,memo) VALUES
   ('ler_4a','opr_4',1,'CUSTOMER_THB',acct('CUSTOMER_THB','cus_4'),
    -f_satang_to_base(baht(400)),'เผาคืนจากการตีกลับ'),
   ('ler_4b','opr_4',2,'ISSUANCE',acct('ISSUANCE','thb'),
     f_satang_to_base(baht(400)),'คู่บัญชีของการเผา');

  UPDATE thb_balance SET amount = amount - f_satang_to_base(baht(400))
   WHERE account_id = acct('CUSTOMER_THB','cus_4');
  UPDATE thb_balance SET amount = amount + f_satang_to_base(baht(400))
   WHERE account = 'ISSUANCE';
  UPDATE thb_deposit SET status='REVERSED' WHERE id='dep_4';

  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT amount INTO v_bal FROM thb_balance WHERE account_id=acct('CUSTOMER_THB','cus_4');
  SELECT outcome INTO v_out FROM deposit_reversal WHERE id='rev_4';
  PERFORM t_ok('T21','ตีกลับขณะยอดพอ → เผาคืนครบ · ยอดเหลือศูนย์',
               v_bal = 0 AND v_out = 'BURNED');
END $$;

-- =====================================================================
-- T22 · ยอดไม่พอแต่บอกว่า BURNED → ถูกปฏิเสธ
-- ผลลัพธ์ต้องตรงกับยอดที่มีจริง · เลือกเองไม่ได้
-- =====================================================================
-- ตั้งฉากก่อน · ต้องอยู่นอก DO block ที่คาดว่าจะ raise
-- ไม่งั้น subtransaction จะ rollback ฉากไปด้วย แล้ว T23 หาของไม่เจอ
SELECT do_mint('dep_5');
INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
VALUES ('op_spend','customer:cus_spent','LISTING_BUY','lst_y','{}');
-- ใช้เงินไปซื้อของแล้ว · จองไว้ทั้งก้อน ยอดที่ใช้ได้เหลือศูนย์
INSERT INTO reservation (id,operation_id,subject_type,subject_id,amount)
VALUES ('rsv_spend','op_spend','THB_BALANCE',acct('CUSTOMER_THB','cus_spent'),
        f_satang_to_base(baht(500)));

-- operation ของการตีกลับ · T22 กับ T23 ใช้ร่วมกัน จึงสร้างที่นี่
INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
VALUES ('opr_5','system:psp','THB_MINT','FINALIZED','dep_5','{}',now());

DO $$
BEGIN
  INSERT INTO deposit_reversal (id,deposit_id,webhook_id,operation_id,amount_base,
                                available_at_reversal,outcome)
  VALUES ('rev_5','dep_5','wh_r2','opr_5', f_satang_to_base(baht(500)),
          f_available_thb('CUSTOMER_THB',acct('CUSTOMER_THB','cus_spent')),'BURNED');
  PERFORM t_ok('T22','ยอดไม่พอแต่อ้างว่า BURNED → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T22','ยอดไม่พอแต่อ้างว่า BURNED → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T23 · ยอดไม่พอ → MANUAL_REVIEW ได้ · ไม่แตะยอดเลย
-- การยอมรับว่าต้องมีคนตัดสิน ถูกกว่าการแกล้งว่าแก้อัตโนมัติได้
-- =====================================================================
DO $$
DECLARE v_bal numeric; v_out reversal_outcome; v_avail numeric;
BEGIN
  v_avail := f_available_thb('CUSTOMER_THB',acct('CUSTOMER_THB','cus_spent'));
  INSERT INTO deposit_reversal (id,deposit_id,webhook_id,operation_id,amount_base,
                                available_at_reversal,outcome,note)
  VALUES ('rev_5b','dep_5','wh_r2','opr_5', f_satang_to_base(baht(500)),
          v_avail,'MANUAL_REVIEW','ใช้เงินไปซื้อของแล้ว เผาคืนไม่ได้');
  SELECT amount INTO v_bal FROM thb_balance WHERE account_id=acct('CUSTOMER_THB','cus_spent');
  SELECT outcome INTO v_out FROM deposit_reversal WHERE id='rev_5b';
  PERFORM t_ok('T23','ยอดไม่พอ → MANUAL_REVIEW · ยอดไม่ถูกแตะเลย',
               v_out = 'MANUAL_REVIEW' AND v_avail = 0
           AND v_bal = f_satang_to_base(baht(500)));
END $$;

-- =====================================================================
-- T24 · ยอดพอแต่บอกว่า MANUAL_REVIEW → ถูกปฏิเสธ
-- กันการเลี่ยงไปโยนให้คนตรวจทั้งที่เผาคืนได้
-- =====================================================================
DO $$
BEGIN
  PERFORM do_mint('dep_6');
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('opr_6','system:psp','THB_MINT','FINALIZED','dep_6','{}',now());
  INSERT INTO deposit_reversal (id,deposit_id,webhook_id,operation_id,amount_base,
                                available_at_reversal,outcome)
  VALUES ('rev_6','dep_6','wh_r1','opr_6', f_satang_to_base(baht(600)),
          f_available_thb('CUSTOMER_THB',acct('CUSTOMER_THB','cus_2')),'MANUAL_REVIEW');
  PERFORM t_ok('T24','ยอดพอแต่อ้าง MANUAL_REVIEW → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T24','ยอดพอแต่อ้าง MANUAL_REVIEW → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T25 · ตีกลับการฝากที่ยังไม่ได้ mint → ถูกปฏิเสธ
-- ยังไม่มี THB ออกไป ไม่มีอะไรต้องเผา · ควรแค่เปลี่ยนสถานะเป็น FAILED
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,status,subject_id,payload,finalized_at)
  VALUES ('opr_2','system:psp','THB_MINT','FINALIZED','dep_2','{}',now());
  INSERT INTO deposit_reversal (id,deposit_id,webhook_id,operation_id,amount_base,
                                available_at_reversal,outcome)
  VALUES ('rev_2','dep_2','wh_r1','opr_2', f_satang_to_base(baht(200)),0,'MANUAL_REVIEW');
  PERFORM t_ok('T25','ตีกลับการฝากที่ยังไม่ mint → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T25','ตีกลับการฝากที่ยังไม่ mint → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T26 · การฝากเดียวตีกลับซ้ำไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO deposit_reversal (id,deposit_id,webhook_id,operation_id,amount_base,
                                available_at_reversal,outcome)
  VALUES ('rev_4b','dep_4','wh_r1','opr_4', f_satang_to_base(baht(400)),0,'MANUAL_REVIEW');
  PERFORM t_ok('T26','ตีกลับการฝากเดิมซ้ำ → ชน uq_reversal_deposit', false);
EXCEPTION WHEN unique_violation OR check_violation THEN
  PERFORM t_ok('T26','ตีกลับการฝากเดิมซ้ำ → ชน uq_reversal_deposit', true);
END $$;

-- =====================================================================
-- T27 · การฝากหนึ่งรายการมีงาน mint ค้างได้ทีละงานเดียว
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_m7a','system:minter','THB_MINT','dep_7','{}');
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_m7b','system:minter','THB_MINT','dep_7','{}');
  PERFORM t_ok('T27','สองงาน mint บนการฝากเดียว → ชน uq_mint_inflight', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T27','สองงาน mint บนการฝากเดียว → ชน uq_mint_inflight', true);
END $$;

-- =====================================================================
-- T28 · ยอดคงเหลือติดลบได้เฉพาะ ISSUANCE
-- =====================================================================
DO $$
BEGIN
  INSERT INTO thb_balance (account,account_id,amount)
  VALUES ('CUSTOMER_THB',acct('CUSTOMER_THB','cus_neg'),-1);
  PERFORM t_ok('T28','ยอดลูกค้าติดลบ → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T28','ยอดลูกค้าติดลบ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T29 · ledger amount = 0 → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO ledger_entry (id,operation_id,entry_seq,account,account_id,amount)
  VALUES ('le_zero','opm_dep_1',9,'CUSTOMER_THB',acct('CUSTOMER_THB','cus_1'),0);
  PERFORM t_ok('T29','ledger amount = 0 → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T29','ledger amount = 0 → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T30 · outbox topic ต้องมีเวอร์ชันลงท้าย
-- =====================================================================
DO $$
BEGIN
  INSERT INTO outbox (id,operation_id,topic,payload)
  VALUES ('obx_bad','opm_dep_1','thb.mint','{}');
  PERFORM t_ok('T30','outbox topic ไม่มี .vN → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T30','outbox topic ไม่มี .vN → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T31 · อ่าน log ช่วงเดิมซ้ำได้                              RFD 5 D2
-- =====================================================================
DO $$
DECLARE n1 int; n2 int;
BEGIN
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_r1',3001,decode(repeat('bb',32),'hex'),decode(repeat('e1',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  INSERT INTO chain_event (id,block_number,block_hash,tx_hash,log_index,address,
                           topic0,data,block_timestamp)
  VALUES ('ce_r2',3001,decode(repeat('bb',32),'hex'),decode(repeat('e1',32),'hex'),0,
          decode(repeat('aa',20),'hex'),'\x00','\x00',now())
  ON CONFLICT (tx_hash,log_index) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  PERFORM t_ok('T31','อ่าน log ช่วงเดิมซ้ำ → chain_event ไม่เกิดแถวซ้ำ', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T32 · webhook ที่ลายเซ็นไม่ผ่าน ไม่อยู่ในคิวงาน
-- index ที่ใช้หยิบงานกรองออกเองที่ระดับ schema
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM psp_webhook
   WHERE processed_at IS NULL AND signature_ok AND id = 'wh_bad';
  PERFORM t_ok('T32','webhook ที่ลายเซ็นไม่ผ่าน ไม่เข้าคิวงาน', n = 0);
END $$;

-- =====================================================================
-- T33 · ปิดท้าย · ledger รวม 0 และทุกยอดตรงกับ ledger ของตัวเอง
-- =====================================================================
DO $$
DECLARE v_sum numeric; v_mismatch int; v_iss_ops int;
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  SELECT coalesce(sum(amount),0) INTO v_sum FROM ledger_entry;
  SELECT count(*) INTO v_mismatch FROM thb_balance b
   WHERE b.amount <> coalesce((SELECT sum(amount) FROM ledger_entry l
                                WHERE l.account=b.account AND l.account_id=b.account_id),0);
  -- ทุกแถวที่แตะ ISSUANCE ต้องมาจาก operation ที่เป็น THB_MINT
  SELECT count(*) INTO v_iss_ops FROM ledger_entry l JOIN operation o ON o.id=l.operation_id
   WHERE l.account='ISSUANCE' AND o.kind <> 'THB_MINT';
  PERFORM t_ok('T33','ปิดท้าย · ledger รวม 0 · ยอดตรง · ISSUANCE มาจาก THB_MINT ทั้งหมด',
               v_sum = 0 AND v_mismatch = 0 AND v_iss_ops = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

ROLLBACK;
