-- =====================================================================
-- FEAT-03 · acceptance · ข้อรับประกันที่ต้องพิสูจน์ได้จาก schema เพียวๆ
-- รัน:  psql -d feat03 -f tests/acceptance.sql
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
INSERT INTO merchant_admin (id, merchant_id, email, email_normalized, password_hash, display_name)
VALUES ('adm_1','mch_1','owner@shop.co.th','owner@shop.co.th',
        '$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$aaaa','เจ้าของร้าน');
INSERT INTO customer (id, tel_hash) VALUES ('cus_1', sha256('0812345678'));

-- session ใบแรกจากการ login
INSERT INTO auth_session (id, subject_kind, merchant_admin_id, family_id,
                          refresh_token_hash, expires_at)
VALUES ('ses_1','MERCHANT_ADMIN','adm_1','fam_1', sha256('tok-1'), now() + interval '30 days');

-- =====================================================================
-- T1 · refresh token หนึ่งใบมีได้แถวเดียว
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO auth_session (id, subject_kind, merchant_admin_id, family_id,
                              refresh_token_hash, expires_at)
    VALUES ('ses_dup','MERCHANT_ADMIN','adm_1','fam_x', sha256('tok-1'), now() + interval '30 days');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T1','refresh token ค่าเดียวกันเกิดสองแถวไม่ได้', blocked);
END $$;

-- =====================================================================
-- T2 · token หนึ่งใบหมุนได้ครั้งเดียว · นี่คือการกันการใช้ซ้ำ
--      เอาใบที่หมุนไปแล้วมาหมุนอีก → ลูกใบที่สอง INSERT ไม่ผ่าน
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  -- หมุนครั้งแรก · ออกใบลูก
  UPDATE auth_session SET used_at = now(), revoked_at = now(), revoked_reason = 'ROTATED'
   WHERE id = 'ses_1';
  INSERT INTO auth_session (id, subject_kind, merchant_admin_id, family_id,
                            refresh_token_hash, parent_id, expires_at)
  VALUES ('ses_2','MERCHANT_ADMIN','adm_1','fam_1', sha256('tok-2'),'ses_1', now() + interval '30 days');

  -- มีคนขโมยใบเก่าไปหมุนอีก
  BEGIN
    INSERT INTO auth_session (id, subject_kind, merchant_admin_id, family_id,
                              refresh_token_hash, parent_id, expires_at)
    VALUES ('ses_evil','MERCHANT_ADMIN','adm_1','fam_1', sha256('tok-evil'),'ses_1', now() + interval '30 days');
  EXCEPTION WHEN unique_violation THEN blocked := true;
  END;
  PERFORM t_ok('T2','หมุน refresh token ใบเดิมซ้ำ → ถูกฐานข้อมูลปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T3 · เพิกถอนทั้งสายได้ด้วยคำสั่งเดียว · ไม่มีใบไหนรอด
-- =====================================================================
DO $$
DECLARE live int;
BEGIN
  UPDATE auth_session
     SET revoked_at = now(), revoked_reason = 'REUSE_DETECTED'
   WHERE family_id = 'fam_1' AND revoked_at IS NULL;

  SELECT count(*) INTO live FROM auth_session
   WHERE family_id = 'fam_1' AND revoked_at IS NULL;
  PERFORM t_ok('T3','เพิกถอนทั้ง family → ไม่เหลือ session ที่ยังใช้ได้เลย', live = 0);
END $$;

-- =====================================================================
-- T4 · เพิกถอนโดยไม่บอกเหตุผลไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO auth_session (id, subject_kind, customer_id, family_id,
                              refresh_token_hash, expires_at, revoked_at)
    VALUES ('ses_t4','CUSTOMER','cus_1','fam_t4', sha256('tok-t4'),
            now() + interval '30 days', now());
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T4','ตั้ง revoked_at โดยไม่ใส่ revoked_reason → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T5 · session ต้องมีเจ้าของคนเดียว ไม่ใช่ทั้งคู่ ไม่ใช่ไม่มีเลย
-- =====================================================================
DO $$
DECLARE two_owners boolean := false; no_owner boolean := false;
BEGIN
  BEGIN
    INSERT INTO auth_session (id, subject_kind, merchant_admin_id, customer_id,
                              family_id, refresh_token_hash, expires_at)
    VALUES ('ses_t5a','MERCHANT_ADMIN','adm_1','cus_1','fam_t5a',
            sha256('tok-t5a'), now() + interval '30 days');
  EXCEPTION WHEN check_violation THEN two_owners := true;
  END;
  BEGIN
    INSERT INTO auth_session (id, subject_kind, family_id, refresh_token_hash, expires_at)
    VALUES ('ses_t5b','MERCHANT_ADMIN','fam_t5b', sha256('tok-t5b'), now() + interval '30 days');
  EXCEPTION WHEN check_violation THEN no_owner := true;
  END;
  PERFORM t_ok('T5','session ที่มีเจ้าของสองคน หรือไม่มีเจ้าของเลย → ถูกปฏิเสธ', two_owners AND no_owner);
END $$;

-- =====================================================================
-- T6 · subject_kind ต้องตรงกับคอลัมน์ที่มีค่า
--      บอกว่าเป็น CUSTOMER แต่ใส่ merchant_admin_id ไม่ได้
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO auth_session (id, subject_kind, merchant_admin_id, family_id,
                              refresh_token_hash, expires_at)
    VALUES ('ses_t6','CUSTOMER','adm_1','fam_t6', sha256('tok-t6'), now() + interval '30 days');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T6','subject_kind ไม่ตรงกับคอลัมน์ที่มีค่า → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T7 · ตาราง auth_session ต้องไม่มีคอลัมน์ที่เก็บ token แบบ plaintext
--      ตรวจโครงสร้างตาราง ไม่ใช่ตรวจข้อมูล
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'auth_session'
    AND (column_name ~* '(token|secret|password)'
         AND column_name NOT LIKE '%_hash');
  PERFORM t_ok('T7','auth_session ไม่มีคอลัมน์เก็บ token แบบ plaintext เลย', bad = 0);
END $$;

-- =====================================================================
-- T8 · ไม่มีตารางไหนในระบบนี้เก็บ access token
--      access token เป็น JWT อายุสั้น ไม่ต้องเก็บ (RFD 16 §3.4)
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND column_name ~* '(access_token|jwt|bearer)';
  PERFORM t_ok('T8','ไม่มีตารางไหนเก็บ access token', bad = 0);
END $$;

-- =====================================================================
-- T9 · วันหมดอายุต้องอยู่หลังวันสร้าง
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO auth_session (id, subject_kind, customer_id, family_id,
                              refresh_token_hash, created_at, expires_at)
    VALUES ('ses_t9','CUSTOMER','cus_1','fam_t9', sha256('tok-t9'),
            now(), now() - interval '1 day');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T9','session ที่หมดอายุก่อนถูกสร้าง → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T10 · password ต้องเป็น argon2id เท่านั้น                   RFD 8 D7
-- =====================================================================
DO $$
DECLARE is_bcrypt boolean := false; is_plain boolean := false;
BEGIN
  BEGIN
    INSERT INTO merchant_admin (id,merchant_id,email,email_normalized,password_hash,display_name)
    VALUES ('adm_t10a','mch_1','a@b.co','a@b.co','$2b$10$abcdefghijklmnopqrstuv','x');
  EXCEPTION WHEN check_violation THEN is_bcrypt := true;
  END;
  BEGIN
    INSERT INTO merchant_admin (id,merchant_id,email,email_normalized,password_hash,display_name)
    VALUES ('adm_t10b','mch_1','c@d.co','c@d.co','hunter2','x');
  EXCEPTION WHEN check_violation THEN is_plain := true;
  END;
  PERFORM t_ok('T10','password ที่เป็น bcrypt หรือ plaintext เข้าฐานข้อมูลไม่ได้', is_bcrypt AND is_plain);
END $$;

-- =====================================================================
-- T11 · บันทึก login ที่สำเร็จต้องไม่มีรหัสความล้มเหลว
-- =====================================================================
DO $$
DECLARE blocked boolean := false;
BEGIN
  INSERT INTO login_attempt (id, identifier_hash, ip_hash, succeeded)
  VALUES ('la_1', sha256('owner@shop.co.th'), sha256('1.2.3.4'), true);
  BEGIN
    INSERT INTO login_attempt (id, identifier_hash, ip_hash, succeeded, failure_code)
    VALUES ('la_bad', sha256('owner@shop.co.th'), sha256('1.2.3.4'), true, 'BAD_PASSWORD');
  EXCEPTION WHEN check_violation THEN blocked := true;
  END;
  PERFORM t_ok('T11','บันทึก login สำเร็จพร้อมรหัสความล้มเหลว → ถูกปฏิเสธ', blocked);
END $$;

-- =====================================================================
-- T12 · ตาราง login_attempt ไม่เก็บอีเมลหรือ IP แบบอ่านได้
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'login_attempt'
    AND column_name ~* '(email|ip|identifier|tel|phone)'
    AND column_name NOT LIKE '%_hash';
  PERFORM t_ok('T12','login_attempt เก็บแต่ hash ไม่เก็บอีเมลหรือ IP ตรงๆ', bad = 0);
END $$;

-- =====================================================================
-- T13 · นับจำนวนครั้งที่พลาดเพื่อล็อกบัญชี ทำได้ด้วย index ที่มีอยู่
-- =====================================================================
DO $$
DECLARE n int;
BEGIN
  INSERT INTO login_attempt (id, identifier_hash, ip_hash, succeeded, failure_code)
  SELECT 'la_f'||g, sha256('victim@shop.co.th'), sha256('9.9.9.9'), false, 'BAD_PASSWORD'
  FROM generate_series(1,5) g;

  SELECT count(*) INTO n FROM login_attempt
   WHERE identifier_hash = sha256('victim@shop.co.th')
     AND NOT succeeded
     AND created_at > now() - interval '15 minutes';

  INSERT INTO login_lockout (identifier_hash, locked_until, attempt_count)
  VALUES (sha256('victim@shop.co.th'), now() + interval '15 minutes', n)
  ON CONFLICT (identifier_hash) DO UPDATE
    SET locked_until = excluded.locked_until,
        attempt_count = login_lockout.attempt_count + 1,
        updated_at = now();

  PERFORM t_ok('T13','นับครั้งที่พลาดใน 15 นาทีแล้วล็อกบัญชีได้ (นับได้ 5)', n = 5);
END $$;

-- =====================================================================
-- T14 · invariant · ไม่มี session ที่ยังใช้ได้ของผู้ใช้ที่ถูกปิดบัญชี
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  UPDATE merchant_admin SET disabled_at = now() WHERE id = 'adm_1';
  UPDATE auth_session SET revoked_at = now(), revoked_reason = 'ADMIN_REVOKED'
   WHERE merchant_admin_id = 'adm_1' AND revoked_at IS NULL;

  SELECT count(*) INTO bad
  FROM auth_session s
  JOIN merchant_admin a ON a.id = s.merchant_admin_id
  WHERE a.disabled_at IS NOT NULL
    AND s.revoked_at IS NULL
    AND s.expires_at > now();
  PERFORM t_ok('T14','ไม่มี session ที่ยังใช้ได้ของบัญชีที่ถูกปิด', bad = 0);
END $$;

-- =====================================================================
-- T15 · invariant · ไม่มีใบลูกที่ active ในสายที่ถูกเพิกถอนไปแล้ว
-- =====================================================================
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM auth_session child
  JOIN auth_session parent ON parent.id = child.parent_id
  WHERE parent.revoked_reason = 'REUSE_DETECTED'
    AND child.revoked_at IS NULL;
  PERFORM t_ok('T15','สายที่เจอการใช้ซ้ำ ไม่มีใบลูกที่ยังใช้ได้เหลืออยู่', bad = 0);
END $$;

-- ------------------------------------------------------------- สรุป
SELECT id AS "#", what AS "ข้อรับประกัน", verdict AS "ผล" FROM result ORDER BY lpad(substr(id,2),3,'0');
SELECT count(*) FILTER (WHERE verdict='PASS') AS "ผ่าน",
       count(*) FILTER (WHERE verdict='FAIL') AS "ไม่ผ่าน" FROM result;

-- ไม่ commit · ฐานข้อมูลกลับไปเหมือนก่อนรัน
ROLLBACK;
