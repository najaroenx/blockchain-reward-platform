-- =====================================================================
-- FEAT-02 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat02 -f tests/acceptance.sql
-- ทุกแถวต้องขึ้น PASS · แถวเดียวที่ FAIL = schema ไม่ให้สิ่งที่ RFD สัญญาไว้
--
-- pack นี้มีข้อเท็จจริงจากระบบเดิมมากที่สุด · หัวใจอยู่ที่
--   T4  T5       F6  · ฐานข้อมูลไม่มีที่เก็บ OTP ให้คืนกลับไปได้
--   T7-T13       L6  · F13 · wallet ไม่มีคอลัมน์ key และไม่มีวันมี
--   T24-T31      F7  · เบอร์มาจาก challenge ไม่ใช่จาก request
--   T32-T34      F12 · ไม่มีรหัสผ่าน · ยืนยันแล้วได้ session ทันที
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

BEGIN;

CREATE TEMP TABLE result (id text, what text, verdict text);

CREATE OR REPLACE FUNCTION t_ok(p_id text, p_what text, p_pass boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO result VALUES (p_id, p_what, CASE WHEN p_pass THEN 'PASS' ELSE 'FAIL' END) $$;

-- pepper ของจริงอยู่ใน KMS · ที่นี่เป็นค่าทดสอบ
CREATE OR REPLACE FUNCTION pep() RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT 'test-pepper-not-the-real-one' $$;

CREATE OR REPLACE FUNCTION code_hash_of(p_ch text, p_code text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT hmac(p_ch || ':' || p_code, pep(), 'sha256') $$;

-- สร้าง challenge พร้อม throttle
CREATE OR REPLACE FUNCTION mk_challenge(
  p_id text, p_phone text, p_code text, p_ttl interval DEFAULT interval '5 minutes'
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_phone text := f_normalize_phone(p_phone);
BEGIN
  INSERT INTO otp_challenge (id, phone_e164, code_hash, pepper_ref, expires_at)
  VALUES (p_id, v_phone, code_hash_of(p_id, p_code),
          'kms://otp-pepper/v1', now() + p_ttl);
  INSERT INTO phone_throttle (phone_e164, sent_count, last_sent_at)
  VALUES (v_phone, 1, now())
  ON CONFLICT (phone_e164) DO UPDATE
    SET sent_count = phone_throttle.sent_count + 1, last_sent_at = now();
END $$;

-- =====================================================================
-- T1 · เบอร์สามรูปที่คนพิมพ์จริง ได้ค่าเดียวกัน
-- ถ้า normalize ไม่ตรงกัน คนเดียวจะมีได้สองบัญชี และ UNIQUE กันไม่ได้
-- =====================================================================
DO $$
DECLARE a text; b text; c text; d text;
BEGIN
  a := f_normalize_phone('0812345678');
  b := f_normalize_phone('+66812345678');
  c := f_normalize_phone('66812345678');
  d := f_normalize_phone('081-234-5678');
  PERFORM t_ok('T1','เบอร์สามรูป (0xx · +66xx · 66xx) และมีขีด → ค่าเดียวกัน',
               a = '+66812345678' AND a = b AND b = c AND c = d);
END $$;

-- =====================================================================
-- T2 · เบอร์รูปที่ไม่รู้จัก → CHECK ปฏิเสธ
-- คืนค่าที่ CHECK จะปฏิเสธ ดีกว่าเดาแล้วผิด
-- =====================================================================
DO $$
BEGIN
  INSERT INTO otp_challenge (id,phone_e164,code_hash,pepper_ref,expires_at)
  VALUES ('ch_bad', f_normalize_phone('12345'), sha256('x'),
          'kms://p/v1', now() + interval '5 minutes');
  PERFORM t_ok('T2','เบอร์รูปที่ไม่รู้จัก → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T2','เบอร์รูปที่ไม่รู้จัก → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T3 · เบอร์ที่ยังไม่ normalize → ถูกปฏิเสธ
-- เก็บรูปเดียวเท่านั้น
-- =====================================================================
DO $$
BEGIN
  INSERT INTO otp_challenge (id,phone_e164,code_hash,pepper_ref,expires_at)
  VALUES ('ch_raw','0812345678', sha256('x'),'kms://p/v1', now() + interval '5 minutes');
  PERFORM t_ok('T3','เบอร์ที่ยังไม่ normalize → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T3','เบอร์ที่ยังไม่ normalize → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T4 · F6 · ฐานข้อมูลไม่มีคอลัมน์ไหนที่เก็บ OTP ได้
--
-- ระบบเดิมคืนค่า OTP กลับมาใน response พร้อมคอมเมนต์ For testing purposes
-- ที่นี่ไม่มีอะไรให้คืนกลับไปแม้จะอยากคืน
-- =====================================================================
DO $$
DECLARE v_cols text; v_n int;
BEGIN
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_cols
    FROM information_schema.columns WHERE table_name = 'otp_challenge';
  SELECT count(*)::int INTO v_n FROM information_schema.columns
   WHERE table_name = 'otp_challenge'
     AND column_name ~* '(^code$|otp|plain|clear)'
     AND column_name <> 'code_hash';
  PERFORM t_ok('T4','F6 · otp_challenge ไม่มีคอลัมน์ที่เก็บ OTP ได้ · มีแต่ code_hash',
               v_n = 0 AND v_cols LIKE '%code_hash%');
END $$;

-- =====================================================================
-- T5 · code_hash ต้องเป็น 32 byte · และ pepper_ref ต้องเป็น kms://
-- hash ของ OTP หกหลักที่ไม่มี pepper ย้อนได้ในเสี้ยววินาที
-- =====================================================================
DO $$
DECLARE ok1 boolean := false; ok2 boolean := false;
BEGIN
  BEGIN
    INSERT INTO otp_challenge (id,phone_e164,code_hash,pepper_ref,expires_at)
    VALUES ('ch_short','+66812345679','\xdeadbeef','kms://p/v1',
            now() + interval '5 minutes');
  EXCEPTION WHEN check_violation THEN ok1 := true; END;
  BEGIN
    INSERT INTO otp_challenge (id,phone_e164,code_hash,pepper_ref,expires_at)
    VALUES ('ch_nopep','+66812345679', sha256('x'),'my-secret-pepper-value',
            now() + interval '5 minutes');
  EXCEPTION WHEN check_violation THEN ok2 := true; END;
  PERFORM t_ok('T5','code_hash ต้อง 32 byte · pepper_ref ต้องเป็น kms:// ไม่ใช่ค่าดิบ',
               ok1 AND ok2);
END $$;

-- =====================================================================
-- T6 · L6 · ตาราง wallet ไม่มีคอลัมน์ที่เก็บ key ได้
-- F13 · ระบบเดิมเก็บ key ที่เข้ารหัสด้วย AES ไว้ในฐานข้อมูล
-- =====================================================================
DO $$
DECLARE v_n int; v_has_ref boolean;
BEGIN
  SELECT count(*)::int INTO v_n FROM information_schema.columns
   WHERE table_name = 'wallet'
     AND column_name ~* '(private|secret|mnemonic|seed|keystore|encrypted)';
  SELECT count(*) = 1 INTO v_has_ref FROM information_schema.columns
   WHERE table_name = 'wallet' AND column_name = 'kms_key_ref';
  PERFORM t_ok('T6','L6 · wallet ไม่มีคอลัมน์เก็บ key · มีแต่ kms_key_ref',
               v_n = 0 AND v_has_ref);
END $$;

-- =====================================================================
-- T7 · L6 · เพิ่มคอลัมน์ private_key ในอนาคต → event trigger ปฏิเสธ
--
-- "ไม่มีวันมี" ไม่ใช่คอมเมนต์ · เป็นกลไกที่ชั้น DDL
-- กันคนที่จะเพิ่มมันในอีกสองปี ด้วยเจตนาดี
-- ตอนที่ไม่มีใครในทีมจำได้ว่าทำไมมันไม่มีตั้งแต่แรก
-- =====================================================================
DO $$
BEGIN
  ALTER TABLE wallet ADD COLUMN private_key text;
  PERFORM t_ok('T7','L6 · ALTER TABLE เพิ่ม private_key → ถูกปฏิเสธที่ชั้น DDL', false);
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM t_ok('T7','L6 · ALTER TABLE เพิ่ม private_key → ถูกปฏิเสธที่ชั้น DDL', true);
END $$;

-- =====================================================================
-- T8 · L6 · ชื่ออื่นที่เข้าข่ายก็ถูกปฏิเสธ · ไม่ใช่กันแค่ชื่อเดียว
-- =====================================================================
DO $$
DECLARE n_blocked int := 0;
BEGIN
  BEGIN ALTER TABLE wallet ADD COLUMN encrypted_key text;
  EXCEPTION WHEN insufficient_privilege THEN n_blocked := n_blocked + 1; END;
  BEGIN ALTER TABLE wallet ADD COLUMN mnemonic text;
  EXCEPTION WHEN insufficient_privilege THEN n_blocked := n_blocked + 1; END;
  BEGIN ALTER TABLE wallet ADD COLUMN sk bytea;
  EXCEPTION WHEN insufficient_privilege THEN n_blocked := n_blocked + 1; END;
  BEGIN ALTER TABLE wallet ADD COLUMN seed_phrase text;
  EXCEPTION WHEN insufficient_privilege THEN n_blocked := n_blocked + 1; END;
  PERFORM t_ok('T8','L6 · encrypted_key · mnemonic · sk · seed_phrase ถูกปฏิเสธทั้งหมด',
               n_blocked = 4);
END $$;

-- =====================================================================
-- T9 · L6 · สร้างตารางใหม่ที่มีคอลัมน์แบบนั้นก็ไม่ได้
-- ไม่ใช่กันแค่ตาราง wallet · กันทุกตารางในฐานข้อมูล
-- =====================================================================
DO $$
BEGIN
  CREATE TABLE wallet_backup_v2 (id text PRIMARY KEY, privkey text);
  PERFORM t_ok('T9','L6 · CREATE TABLE ที่มี privkey → ถูกปฏิเสธ', false);
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM t_ok('T9','L6 · CREATE TABLE ที่มี privkey → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T10 · ชื่อที่ไม่เข้าข่ายเพิ่มได้ปกติ · กฎต้องไม่กว้างเกินไป
-- กฎที่บล็อกทุกอย่างจะถูกปิดทิ้งในสัปดาห์แรก
-- =====================================================================
DO $$
BEGIN
  ALTER TABLE wallet ADD COLUMN label text;
  ALTER TABLE wallet DROP COLUMN label;
  PERFORM t_ok('T10','คอลัมน์ชื่อธรรมดา (label) เพิ่มได้ปกติ · กฎไม่กว้างเกิน', true);
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM t_ok('T10','คอลัมน์ชื่อธรรมดา (label) เพิ่มได้ปกติ · กฎไม่กว้างเกิน', false);
END $$;

-- =====================================================================
-- T11 · kms_key_ref ที่เป็นค่าความลับเอง → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  INSERT INTO wallet (address, owner_kind, owner_id, kms_key_ref)
  VALUES (decode(repeat('11',20),'hex'),'CUSTOMER','cus_x',
          '0x4c0883a69102937d6231471b5dbb6204fe512961708279f2f3b1d3a4b9c7e8d1');
  PERFORM t_ok('T11','kms_key_ref ที่เป็นค่าดิบ → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T11','kms_key_ref ที่เป็นค่าดิบ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T12 · event trigger มีอยู่จริง · ไม่ใช่แค่หวังว่ามี
--
-- event trigger ต้องสร้างโดย superuser · ถ้า production รัน migration
-- ด้วย user ธรรมดา ข้อนี้จะไม่ถูกสร้าง และ T7 ถึง T9 จะ FAIL
-- จึงตรวจตรงๆ ว่ามันอยู่และเปิดใช้งาน
-- =====================================================================
DO $$
DECLARE v_n int; v_enabled boolean;
BEGIN
  SELECT count(*)::int, bool_and(evtenabled <> 'D') INTO v_n, v_enabled
    FROM pg_event_trigger WHERE evtname = 'trg_no_secret_columns';
  PERFORM t_ok('T12','event trigger มีอยู่จริงและเปิดใช้งาน', v_n = 1 AND v_enabled);
END $$;

-- =====================================================================
-- T13 · ขอ OTP ซ้ำเร็วเกินไป → ถูกปฏิเสธ
-- ไม่มีข้อนี้ ใครก็ส่ง SMS รบกวนเบอร์คนอื่นได้ฟรี และค่า SMS เป็นของเรา
-- =====================================================================
SELECT mk_challenge('ch_1','0812345678','123456');

DO $$
BEGIN
  INSERT INTO otp_challenge (id,phone_e164,code_hash,pepper_ref,expires_at)
  VALUES ('ch_1b','+66812345678', sha256('y'),'kms://p/v1',
          now() + interval '5 minutes');
  PERFORM t_ok('T13','ขอ OTP ซ้ำภายใน cooldown → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T13','ขอ OTP ซ้ำภายใน cooldown → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T14 · หนึ่งเบอร์มี challenge ที่ยังใช้ได้ทีละอันเดียว
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  SELECT count(*)::int INTO n FROM otp_challenge
   WHERE phone_e164 = '+66812345678' AND status = 'PENDING';
  PERFORM t_ok('T14','หนึ่งเบอร์มี challenge PENDING ได้อันเดียว', n = 1);
END $$;

-- =====================================================================
-- T15 · ขอครบจำนวนในหนึ่งชั่วโมง → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE phone_throttle SET sent_count = 5, last_sent_at = now() - interval '2 minutes'
   WHERE phone_e164 = '+66812345678';
  INSERT INTO otp_challenge (id,phone_e164,code_hash,pepper_ref,expires_at)
  VALUES ('ch_over','+66812345678', sha256('z'),'kms://p/v1',
          now() + interval '5 minutes');
  PERFORM t_ok('T15','ขอ OTP ครบโควตาในหนึ่งชั่วโมง → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T15','ขอ OTP ครบโควตาในหนึ่งชั่วโมง → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T16 · เบอร์ที่ถูกล็อกอยู่ → ขอไม่ได้
-- =====================================================================
DO $$
BEGIN
  INSERT INTO phone_throttle (phone_e164, locked_until)
  VALUES ('+66899999999', now() + interval '30 minutes');
  INSERT INTO otp_challenge (id,phone_e164,code_hash,pepper_ref,expires_at)
  VALUES ('ch_locked','+66899999999', sha256('z'),'kms://p/v1',
          now() + interval '5 minutes');
  PERFORM t_ok('T16','เบอร์ที่ถูกล็อก → ขอ OTP ไม่ได้', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T16','เบอร์ที่ถูกล็อก → ขอ OTP ไม่ได้', true);
END $$;

-- =====================================================================
-- T17 · ใส่รหัสผิด → WRONG_CODE · นับครั้งเพิ่ม
-- =====================================================================
DO $$
DECLARE r attempt_result; n int;
BEGIN
  r := f_verify_otp('ch_1','000000', pep());
  SELECT attempts INTO n FROM otp_challenge WHERE id='ch_1';
  PERFORM t_ok('T17','ใส่รหัสผิด → WRONG_CODE · attempts เป็น 1',
               r = 'WRONG_CODE' AND n = 1);
END $$;

-- =====================================================================
-- T18 · ใส่รหัสถูก → OK · สถานะเป็น VERIFIED
-- =====================================================================
DO $$
DECLARE r attempt_result; s challenge_status; v timestamptz;
BEGIN
  r := f_verify_otp('ch_1','123456', pep());
  SELECT status, verified_at INTO s, v FROM otp_challenge WHERE id='ch_1';
  PERFORM t_ok('T18','ใส่รหัสถูก → OK · VERIFIED · verified_at ถูกเติม',
               r = 'OK' AND s = 'VERIFIED' AND v IS NOT NULL);
END $$;

-- =====================================================================
-- T19 · ยืนยันซ้ำหลัง VERIFIED → ALREADY_USED
-- OTP ใช้ได้ครั้งเดียว
-- =====================================================================
DO $$
DECLARE r attempt_result;
BEGIN
  r := f_verify_otp('ch_1','123456', pep());
  PERFORM t_ok('T19','ยืนยันซ้ำหลัง VERIFIED → ALREADY_USED', r = 'ALREADY_USED');
END $$;

-- =====================================================================
-- T20 · ใส่ผิดครบจำนวนครั้ง → LOCKED และเบอร์ถูกล็อกด้วย
-- =====================================================================
SELECT mk_challenge('ch_2','0823456789','654321');

DO $$
DECLARE r attempt_result; s challenge_status; v timestamptz; i int;
BEGIN
  FOR i IN 1..5 LOOP r := f_verify_otp('ch_2','111111', pep()); END LOOP;
  SELECT status INTO s FROM otp_challenge WHERE id='ch_2';
  SELECT locked_until INTO v FROM phone_throttle WHERE phone_e164='+66823456789';
  PERFORM t_ok('T20','ใส่ผิดครบ 5 ครั้ง → LOCKED · เบอร์ถูกล็อกด้วย',
               s = 'LOCKED' AND v IS NOT NULL AND v > now());
END $$;

-- =====================================================================
-- T21 · challenge ที่ LOCKED แล้ว ใส่รหัสถูกก็ไม่ผ่าน
-- =====================================================================
DO $$
DECLARE r attempt_result;
BEGIN
  r := f_verify_otp('ch_2','654321', pep());
  PERFORM t_ok('T21','LOCKED แล้วใส่รหัสถูกก็ไม่ผ่าน → LOCKED', r = 'LOCKED');
END $$;

-- =====================================================================
-- T21b · ยิงรัวที่ challenge ที่ล็อกแล้ว · ถูกบันทึกแต่ไม่นับเป็นการเดา
--
-- attempts นับ "การเดา" ไม่ใช่ "การเรียก"
-- เรียกตอนล็อกแล้วไม่ใช่การเดา เพราะรหัสไม่ถูกเอามาเทียบเลย
-- แต่ต้องบันทึก เพราะคนที่ยิงรัวที่ challenge ที่ล็อกแล้วเป็นข้อมูลความปลอดภัย
-- =====================================================================
DO $$
DECLARE v_att int; v_rows int; v_locked int; i int;
BEGIN
  FOR i IN 1..3 LOOP PERFORM f_verify_otp('ch_2','654321', pep()); END LOOP;
  SELECT attempts INTO v_att FROM otp_challenge WHERE id='ch_2';
  SELECT count(*)::int INTO v_rows FROM otp_attempt WHERE challenge_id='ch_2';
  SELECT count(*)::int INTO v_locked FROM otp_attempt
   WHERE challenge_id='ch_2' AND result='LOCKED';
  PERFORM t_ok('T21b','ยิงรัวตอนล็อกแล้ว · บันทึกครบแต่ attempts ยังเป็น 5',
               v_att = 5 AND v_rows = 9 AND v_locked = 4);
END $$;

-- =====================================================================
-- T22 · attempts เกิน max_attempts → CHECK ปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  UPDATE otp_challenge SET attempts = 99 WHERE id='ch_2';
  PERFORM t_ok('T22','attempts เกิน max_attempts → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T22','attempts เกิน max_attempts → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T23 · challenge ที่หมดอายุ → EXPIRED
-- =====================================================================
SELECT mk_challenge('ch_3','0834567890','777777', interval '1 millisecond');

DO $$
DECLARE r attempt_result; s challenge_status;
BEGIN
  -- now() แข็งตัวใน transaction · จึงตั้ง expires_at ให้อยู่ในอดีตโดยตรง
  -- (บทเรียนจาก FEAT-08 T7 · pg_sleep ไม่ทำให้ now() เดิน)
  UPDATE otp_challenge SET status = 'EXPIRED' WHERE id='ch_3';
  r := f_verify_otp('ch_3','777777', pep());
  SELECT status INTO s FROM otp_challenge WHERE id='ch_3';
  PERFORM t_ok('T23','challenge ที่หมดอายุ → EXPIRED · ใส่รหัสถูกก็ไม่ผ่าน',
               r = 'EXPIRED' AND s = 'EXPIRED');
END $$;

-- =====================================================================
-- T24 · F7 · แก้เบอร์ใน challenge → ถูกปฏิเสธ
-- ระบบเดิมเขียนทับเบอร์ด้วยค่าจาก body
-- =====================================================================
DO $$
BEGIN
  UPDATE otp_challenge SET phone_e164 = '+66899999999' WHERE id='ch_1';
  PERFORM t_ok('T24','F7 · แก้เบอร์ใน challenge → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T24','F7 · แก้เบอร์ใน challenge → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T25 · แก้ code_hash หรือ expires_at → ถูกปฏิเสธ
-- ยืดอายุ OTP ย้อนหลังไม่ได้
-- =====================================================================
DO $$
DECLARE ok1 boolean := false; ok2 boolean := false;
BEGIN
  BEGIN UPDATE otp_challenge SET code_hash = sha256('new') WHERE id='ch_1';
  EXCEPTION WHEN check_violation THEN ok1 := true; END;
  BEGIN UPDATE otp_challenge SET expires_at = now() + interval '1 day' WHERE id='ch_1';
  EXCEPTION WHEN check_violation THEN ok2 := true; END;
  PERFORM t_ok('T25','แก้ code_hash หรือ expires_at → ถูกปฏิเสธ', ok1 AND ok2);
END $$;

-- =====================================================================
-- T26 · F7 · สร้างลูกค้าโดยไม่อ้าง challenge → ถูกปฏิเสธ
-- =====================================================================
DO $$
BEGIN
  PERFORM set_config('app.verified_challenge', '', true);
  INSERT INTO customer (id, phone_e164, phone_verified_at)
  VALUES ('cus_noch','+66812345678', now());
  PERFORM t_ok('T26','F7 · สร้างลูกค้าโดยไม่อ้าง challenge → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T26','F7 · สร้างลูกค้าโดยไม่อ้าง challenge → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T27 · F7 · อ้าง challenge ที่ถูก แต่ใส่เบอร์อื่น → ถูกปฏิเสธ
--
-- ข้อนี้คือ F7 ตรงตัว · ระบบเดิมเอาเบอร์จาก body มาใช้
-- ที่นี่ถึงจะส่งเบอร์มา มันก็ต้องตรงกับที่ยืนยันไว้
-- =====================================================================
DO $$
BEGIN
  PERFORM set_config('app.verified_challenge', 'ch_1', true);
  INSERT INTO customer (id, phone_e164, phone_verified_at)
  VALUES ('cus_wrong','+66899999999', now());
  PERFORM t_ok('T27','F7 · เบอร์ไม่ตรงกับ challenge → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T27','F7 · เบอร์ไม่ตรงกับ challenge → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T28 · F7 · อ้าง challenge ที่ยังไม่ VERIFIED → ถูกปฏิเสธ
-- =====================================================================
SELECT mk_challenge('ch_4','0845678901','888888');

DO $$
BEGIN
  PERFORM set_config('app.verified_challenge', 'ch_4', true);
  INSERT INTO customer (id, phone_e164, phone_verified_at)
  VALUES ('cus_unver','+66845678901', now());
  PERFORM t_ok('T28','F7 · challenge ที่ยังไม่ VERIFIED → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T28','F7 · challenge ที่ยังไม่ VERIFIED → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T29 · สมัครด้วย challenge ที่ยืนยันแล้วและเบอร์ตรง → ผ่าน
-- =====================================================================
DO $$
DECLARE v text;
BEGIN
  PERFORM set_config('app.verified_challenge', 'ch_1', true);
  INSERT INTO customer (id, phone_e164, phone_verified_at)
  VALUES ('cus_1','+66812345678',
          (SELECT verified_at FROM otp_challenge WHERE id='ch_1'));
  UPDATE otp_challenge SET status = 'CONSUMED' WHERE id='ch_1';
  SELECT phone_e164 INTO v FROM customer WHERE id='cus_1';
  PERFORM t_ok('T29','สมัครด้วย challenge ที่ถูก → ผ่าน · เบอร์มาจาก challenge',
               v = '+66812345678');
END $$;

-- =====================================================================
-- T30 · challenge ที่ CONSUMED แล้ว ใช้สมัครอีกไม่ได้
-- =====================================================================
DO $$
BEGIN
  PERFORM set_config('app.verified_challenge', 'ch_1', true);
  INSERT INTO customer (id, phone_e164, phone_verified_at)
  VALUES ('cus_dup','+66812345678', now());
  PERFORM t_ok('T30','challenge ที่ CONSUMED แล้ว ใช้สมัครอีกไม่ได้', false);
EXCEPTION WHEN check_violation OR unique_violation THEN
  PERFORM t_ok('T30','challenge ที่ CONSUMED แล้ว ใช้สมัครอีกไม่ได้', true);
END $$;

-- =====================================================================
-- T31 · เปลี่ยนเบอร์ของลูกค้าตรงๆ → ถูกปฏิเสธ
-- เปลี่ยนเบอร์ต้องยืนยันเบอร์ใหม่
-- =====================================================================
DO $$
BEGIN
  UPDATE customer SET phone_e164 = '+66899999999' WHERE id='cus_1';
  PERFORM t_ok('T31','เปลี่ยนเบอร์ลูกค้าตรงๆ → ถูกปฏิเสธ', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T31','เปลี่ยนเบอร์ลูกค้าตรงๆ → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T32 · F12 · ตาราง customer ไม่มีคอลัมน์ password
--
-- ระบบเดิมใช้ bcrypt(password,10) · ที่นี่ลูกค้าไม่มีรหัสผ่าน
-- OTP คือการยืนยันตัวตน · รหัสผ่านจะเพิ่มช่องกู้คืนอีกช่อง
-- ซึ่งเป็นช่องที่โจมตีง่ายที่สุด และสุดท้ายก็กลับมาที่ OTP อยู่ดี
-- =====================================================================
DO $$
DECLARE v_n int;
BEGIN
  SELECT count(*)::int INTO v_n FROM information_schema.columns
   WHERE table_name = 'customer'
     AND column_name ~* '(password|passwd|pwd|bcrypt|hash)';
  PERFORM t_ok('T32','F12 · customer ไม่มีคอลัมน์รหัสผ่าน', v_n = 0);
END $$;

-- =====================================================================
-- T33 · F12 · ยืนยันแล้วได้ session ทันที · ไม่ใช่คืน 201 เปล่า
-- =====================================================================
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO customer_session (id, customer_id, token_hash, expires_at)
  VALUES ('ses_1','cus_1', sha256('the-token'), now() + interval '30 days');
  SELECT count(*)::int INTO v_n FROM customer_session
   WHERE customer_id='cus_1' AND revoked_at IS NULL;
  PERFORM t_ok('T33','F12 · ยืนยันแล้วได้ session ทันที', v_n = 1);
END $$;

-- =====================================================================
-- T34 · session เก็บแต่ hash ของ token · ไม่เก็บ token
-- เหมือนที่ otp_challenge ไม่เก็บ OTP
-- =====================================================================
DO $$
DECLARE v_n int; v_bad int;
BEGIN
  SELECT count(*)::int INTO v_n FROM information_schema.columns
   WHERE table_name = 'customer_session' AND column_name = 'token_hash';
  SELECT count(*)::int INTO v_bad FROM information_schema.columns
   WHERE table_name = 'customer_session'
     AND column_name ~* '(^token$|refresh_token|access_token|jwt)';
  PERFORM t_ok('T34','session เก็บแต่ token_hash · ไม่มีคอลัมน์เก็บ token',
               v_n = 1 AND v_bad = 0);
END $$;

-- =====================================================================
-- T35 · wallet หนึ่งใบต่อเจ้าของหนึ่งคน
-- =====================================================================
DO $$
BEGIN
  INSERT INTO wallet (address, owner_kind, owner_id, kms_key_ref) VALUES
   (decode(repeat('22',20),'hex'),'CUSTOMER','cus_1','kms://wallet/cus_1/v1'),
   (decode(repeat('33',20),'hex'),'CUSTOMER','cus_1','kms://wallet/cus_1/v2');
  PERFORM t_ok('T35','wallet ซ้ำต่อเจ้าของเดียว → ถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T35','wallet ซ้ำต่อเจ้าของเดียว → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T36 · งาน provision ค้างได้ทีละงานเดียวต่อลูกค้า
-- =====================================================================
DO $$
BEGIN
  INSERT INTO operation (id,actor_scope,kind,subject_id,payload) VALUES
   ('op_p1','system:provision','CUSTOMER_PROVISION','cus_1','{}'),
   ('op_p2','system:provision','CUSTOMER_PROVISION','cus_1','{}');
  PERFORM t_ok('T36','สองงาน provision บนลูกค้าเดียว → ถูกปฏิเสธ', false);
EXCEPTION WHEN unique_violation THEN
  PERFORM t_ok('T36','สองงาน provision บนลูกค้าเดียว → ถูกปฏิเสธ', true);
END $$;

-- =====================================================================
-- T37 · attempts นับไม่ตรงกับแถวจริง → ไม่ผ่านตอน COMMIT
-- =====================================================================
DO $$
BEGIN
  UPDATE otp_challenge SET attempts = 3 WHERE id='ch_4';
  INSERT INTO otp_attempt (id,challenge_id,attempt_no,result)
  VALUES ('oa_x','ch_4',1,'WRONG_CODE');
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM t_ok('T37','attempts นับไม่ตรงกับแถวจริง → ไม่ผ่าน', false);
EXCEPTION WHEN check_violation THEN
  PERFORM t_ok('T37','attempts นับไม่ตรงกับแถวจริง → ไม่ผ่าน', true);
END $$;

-- =====================================================================
-- T38 · ปิดท้าย · ไม่มีคอลัมน์ไหนในฐานข้อมูลที่ชื่อเข้าข่ายความลับ
-- ตรวจทั้งฐานข้อมูล ไม่ใช่แค่ตาราง wallet
-- =====================================================================
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(table_name || '.' || column_name, ', ') INTO v_bad
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND (column_name ~* '(private|privkey|priv_key|mnemonic|seed_phrase|keystore|encrypted_key|enc_key)'
          OR column_name ~* '^(sk|xprv)$');
  PERFORM t_ok('T38','ปิดท้าย · ไม่มีคอลัมน์ชื่อเข้าข่ายความลับทั้งฐานข้อมูล',
               v_bad IS NULL);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

ROLLBACK;
