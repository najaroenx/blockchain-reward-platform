-- =====================================================================
-- FEAT-01 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat01 -f tests/acceptance.sql
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
INSERT INTO signer (address, key_ref)
VALUES (decode(repeat('33',20),'hex'), 'kms/signer-1');

-- =====================================================================
-- T1 · สมัครด้วย Idempotency-Key เดิมซ้ำ ต้องไม่เกิดร้านสองร้าน  RFD 3 R1
--      scope ตอนสมัครคือ anon:<sha256(normalized email)> เพราะยังไม่มี actor
-- =====================================================================
DO $$
DECLARE n1 int; n2 int; sc text;
BEGIN
  sc := 'anon:' || encode(sha256('owner@shop.co.th'::bytea), 'hex');

  INSERT INTO idempotency_key (id, scope, key, fingerprint)
  VALUES ('ik_1', sc, '11111111-2222-3333-4444-555555555555', sha256('body'))
  ON CONFLICT (scope, key) DO NOTHING;
  GET DIAGNOSTICS n1 = ROW_COUNT;

  INSERT INTO idempotency_key (id, scope, key, fingerprint)
  VALUES ('ik_2', sc, '11111111-2222-3333-4444-555555555555', sha256('body'))
  ON CONFLICT (scope, key) DO NOTHING;
  GET DIAGNOSTICS n2 = ROW_COUNT;

  PERFORM t_ok('T1','กดสมัครซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows ไม่ throw', n1 = 1 AND n2 = 0);
END $$;

-- =====================================================================
-- T2 · อีเมลเดียวกันที่พิมพ์ต่างกัน สมัครซ้ำไม่ได้          RFD 8 §3.3
--      "  Owner@Shop.CO.TH " กับ "owner@shop.co.th" คือคนเดียวกัน
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO merchant (id, name) VALUES ('mch_1','ร้านทดสอบ');
  INSERT INTO merchant_admin (id, merchant_id, email, email_normalized, password_hash, display_name)
  VALUES ('adm_1','mch_1','Owner@Shop.CO.TH', lower(btrim('  Owner@Shop.CO.TH ')),
          '$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$aaaa','เจ้าของร้าน');
  BEGIN
    INSERT INTO merchant (id, name) VALUES ('mch_2','ร้านซ้ำ');
    INSERT INTO merchant_admin (id, merchant_id, email, email_normalized, password_hash, display_name)
    VALUES ('adm_2','mch_2','owner@shop.co.th','owner@shop.co.th',
            '$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$bbbb','คนอื่น');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T2','อีเมลเดียวกันที่พิมพ์ตัวใหญ่/มีช่องว่าง → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T3 · ตาราง wallet ต้องไม่มีคอลัมน์ที่เก็บ private key         RFD 4 L6
--      ข้อนี้ตรวจโครงสร้างตาราง ไม่ใช่ตรวจข้อมูล
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'wallet'
    AND (column_name ~* '(private|secret|mnemonic|seed|encrypted|cipher)'
         OR column_name ~* '^(pk|priv|sk)$');
  PERFORM t_ok('T3','ตาราง wallet ไม่มีคอลัมน์ที่เก็บ private key เลย', bad = 0);
END $$;

-- =====================================================================
-- T4 · password ต้องเป็น argon2id เท่านั้น                   RFD 8 D7
--      bcrypt ($2a$/$2b$) และ plaintext เข้าไม่ได้
-- =====================================================================
DO $$
DECLARE blocked_bcrypt boolean := false; blocked_plain boolean := false;
BEGIN
  INSERT INTO merchant (id,name) VALUES ('mch_t4','ร้าน T4');
  BEGIN
    INSERT INTO merchant_admin (id,merchant_id,email,email_normalized,password_hash,display_name)
    VALUES ('adm_t4a','mch_t4','a@b.co','a@b.co','$2b$10$abcdefghijklmnopqrstuv','x');
  EXCEPTION WHEN check_violation THEN blocked_bcrypt := true;
  END;
  BEGIN
    INSERT INTO merchant_admin (id,merchant_id,email,email_normalized,password_hash,display_name)
    VALUES ('adm_t4b','mch_t4','c@d.co','c@d.co','hunter2','x');
  EXCEPTION WHEN check_violation THEN blocked_plain := true;
  END;
  PERFORM t_ok('T4','password ที่เป็น bcrypt หรือ plaintext เข้าฐานข้อมูลไม่ได้',
               blocked_bcrypt AND blocked_plain);
END $$;

-- =====================================================================
-- T5 · ร้านเป็น ACTIVE โดยไม่มี activated_at ไม่ได้          RFD 8 §3.4
--      ACTIVE ต้องมาจาก projector หลัง provision จบจริงเท่านั้น
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO merchant (id,name,status) VALUES ('mch_t5','ร้าน T5','ACTIVE');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T5','ตั้งร้านเป็น ACTIVE โดยไม่มี activated_at → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T6 · ร้านหนึ่งมีงาน provision ค้างได้ทีละงานเดียว
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
  VALUES ('op_1','anon:x','MERCHANT_PROVISION','mch_1','{}');
  INSERT INTO outbox (id,operation_id,topic,payload)
  VALUES ('obx_1','op_1','merchant.provision.v1','{}');
  BEGIN
    INSERT INTO operation (id,actor_scope,kind,subject_id,payload)
    VALUES ('op_2','anon:x','MERCHANT_PROVISION','mch_1','{}');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T6','สั่ง provision ร้านเดิมซ้อนกัน → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T7 · topic ของ outbox ต้องมีเวอร์ชันในชื่อ                 RFD 7 D9
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO outbox (id,operation_id,topic,payload)
    VALUES ('obx_bad','op_1','merchant.provision','{}');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T7','topic ที่ไม่มีเวอร์ชันต่อท้าย → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T8 · ห้าม broadcast ก่อน raw_tx ลงตาราง                    RFD 2 R2
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO operation_step (id,operation_id,step_index,name)
  VALUES ('st_1','op_1',1,'whitelistMerchant');
  BEGIN
    UPDATE operation_step SET status = 'SUBMITTED' WHERE id = 'st_1';
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T8','เปลี่ยน step เป็น SUBMITTED โดยไม่มี raw_tx → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T9 · nonce ของ signer ตัวหนึ่งถูกใช้ซ้ำไม่ได้               RFD 4 §3.6
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  UPDATE operation_step
     SET raw_tx='\x02f8', signer_address = decode(repeat('33',20),'hex'),
         nonce = 41, status='SUBMITTED', tx_hash = decode(repeat('ab',32),'hex')
   WHERE id='st_1';
  BEGIN
    INSERT INTO operation_step (id,operation_id,step_index,name,raw_tx,
                                signer_address,nonce,status,tx_hash)
    VALUES ('st_2','op_1',2,'setApprovalForAll','\x02f8',
            decode(repeat('33',20),'hex'), 41, 'SUBMITTED', decode(repeat('cd',32),'hex'));
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T9','ใช้ nonce เดิมของ signer ตัวเดิมซ้ำ → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T10 · ส่ง raw_tx ไบต์เดิมซ้ำ → ไม่เกิดแถวซ้ำ                RFD 2 D4
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO operation_step (id,operation_id,step_index,name,raw_tx,status,tx_hash)
    VALUES ('st_3','op_1',3,'whitelistMerchant','\x02f8','SUBMITTED',
            decode(repeat('ab',32),'hex'));
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T10','ส่ง raw_tx ไบต์เดิมซ้ำ → tx_hash ซ้ำถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T11 · wallet หนึ่งใบต่อหนึ่งเจ้าของ · address ซ้ำไม่ได้
-- =====================================================================
DO $$
DECLARE dup_owner boolean := false; dup_addr boolean := false;
BEGIN
  INSERT INTO wallet (id,address,key_ref,owner_kind,owner_id)
  VALUES ('wal_1', decode(repeat('11',20),'hex'),'kms/m1','MERCHANT','mch_1');
  BEGIN
    INSERT INTO wallet (id,address,key_ref,owner_kind,owner_id)
    VALUES ('wal_2', decode(repeat('22',20),'hex'),'kms/m1b','MERCHANT','mch_1');
  EXCEPTION WHEN unique_violation THEN dup_owner := true;
  END;
  BEGIN
    INSERT INTO wallet (id,address,key_ref,owner_kind,owner_id)
    VALUES ('wal_3', decode(repeat('11',20),'hex'),'kms/other','MERCHANT','mch_t4');
  EXCEPTION WHEN unique_violation THEN dup_addr := true;
  END;
  PERFORM t_ok('T11','ร้านเดิมมี wallet ใบที่สองไม่ได้ · address ซ้ำไม่ได้',
               dup_owner AND dup_addr);
END $$;

-- =====================================================================
-- T12 · invariant · operation ทุกแถวต้องมี outbox คู่กัน      RFD 2 D1
-- =====================================================================
DO $$
DECLARE orphan int;
BEGIN
  SELECT count(*) INTO orphan
  FROM operation o LEFT JOIN outbox b ON b.operation_id = o.id
  WHERE b.id IS NULL;
  PERFORM t_ok('T12','ไม่มี operation ที่ไม่มีใครมาทำ (orphan = 0)', orphan = 0);
END $$;

-- =====================================================================
-- T13 · invariant · ไม่มีร้าน ACTIVE ที่ยังไม่มี wallet
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM merchant m
  LEFT JOIN wallet w ON w.owner_kind = 'MERCHANT' AND w.owner_id = m.id
  WHERE m.status = 'ACTIVE' AND w.id IS NULL;
  PERFORM t_ok('T13','ไม่มีร้านที่ ACTIVE แต่ยังไม่มี wallet', bad = 0);
END $$;

-- =====================================================================
-- T14 · re-index ช่วงเดิมซ้ำได้                              RFD 5 D2
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

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

-- ไม่ commit · ฐานข้อมูลกลับไปเหมือนก่อนรัน
ROLLBACK;
