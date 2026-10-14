# FEAT-03 · Auth · dev pack

ล็อกอิน · access token อายุสั้น · refresh token ที่หมุนทุกครั้งและจับการขโมยได้

```text
pack03/
├── api/openapi.yaml          OpenAPI 3.1 · validate ผ่าน
├── db/migration.sql          DDL · รันบน PostgreSQL 16 จริงแล้ว
├── db/schema.prisma          entity · ตรงกับ DB ทุกคอลัมน์
├── src/types.ts              type ที่ใช้ร่วมกัน · tsc strict ผ่าน
├── src/auth.service.ts       login · refresh · logout
├── tests/acceptance.sql      15 ข้อรับประกัน · PASS 15 FAIL 0
└── diagrams/                 sequence · ER · state
```

---

## การตัดสินใจหลัก · JWT อายุสั้น + session ในฐานข้อมูล

| | access token | refresh token |
|---|---|---|
| รูปแบบ | JWT เซ็นด้วย key ของระบบ | ค่าสุ่ม 256 บิต |
| อายุ | 15 นาที | 30 วัน |
| เก็บในฐานข้อมูลไหม | **ไม่** | เก็บเป็น `sha256` |
| เพิกถอนทันทีได้ไหม | ไม่ | ได้ |

**ทำไมไม่เก็บ access token** — ถ้าเก็บเพื่อให้เพิกถอนได้ทันที ทุก request จะต้อง query ฐานข้อมูล
ซึ่งทำให้ JWT ไม่เหลือข้อดีอะไรเลย ควรใช้ session ล้วนไปตั้งแต่แรก
การเพิกถอนจึงเกิดที่ชั้น refresh แทน

**ราคาที่ยอมจ่าย** — ผู้ใช้ที่เพิ่งถูกแบนยังใช้ access token ใบเดิมได้อีกไม่เกิน 15 นาที
งานที่รับช่องนี้ไม่ได้ (การโอนเงิน การ redeem) ต้องเช็คสถานะบัญชีสดที่ชั้น service
ไม่ใช่เชื่อ token อย่างเดียว

**payload ของ JWT ไม่มี role ไม่มี permission** (RFD 16 D6) — ถ้าสิทธิ์เปลี่ยนระหว่างทาง
token ใบเดิมจะถือสิทธิ์เก่าไปอีก 15 นาที ซึ่งเป็นช่องที่ไม่คุ้มเปิด

---

## หัวใจของ feature นี้ · การหมุนและการจับการขโมย

```text
login      → tok-1                            family F
refresh    → tok-1 ใช้แล้ว  ออก tok-2          family F
refresh    → tok-2 ใช้แล้ว  ออก tok-3          family F

มีคนเอา tok-1 มาใช้อีก
           → เป็นไปได้ทางเดียวคือถูกขโมย
           → เพิกถอนทั้ง family F
           → ทุกเครื่องหลุดพร้อมกัน ต้องล็อกอินใหม่
```

ผู้ใช้จะรู้สึกว่า "อยู่ดีๆ ก็หลุด" ซึ่งถูกต้อง เพราะ token ของเขาอยู่ในมือคนอื่นแล้ว

**สิ่งที่ทำให้กลไกนี้เชื่อถือได้คือ index ไม่ใช่โค้ด**

```sql
CREATE UNIQUE INDEX uq_session_parent
  ON auth_session (parent_id) WHERE parent_id IS NOT NULL;
```

token หนึ่งใบมีลูกได้ใบเดียว · สอง request ที่หมุน token ใบเดียวกันพร้อมกัน
ตัวที่สองชน unique ตรงนี้ โดยไม่ต้อง `SELECT ... FOR UPDATE` มาล็อกไว้ก่อน

**ผลข้างเคียงที่ต้องรู้** — แถวที่ `ROTATED` แล้วห้ามลบทิ้งเร็ว
ถ้าลบ การจับการใช้ซ้ำจะกลายเป็น "ไม่พบ token" ซึ่งแยกไม่ออกจาก token มั่ว
เก็บไว้อย่างน้อยเท่าอายุของ refresh token

---

## login ที่ล้มเหลวต้องเหมือนกันทุกกรณี

```text
อีเมลไม่มีในระบบ  ┐
รหัสผ่านผิด        ├─→  401 INVALID_CREDENTIALS · ข้อความเดียวกัน · เวลาเท่ากัน
บัญชีถูกปิด        ┘
```

สองอย่างที่ต้องทำให้ครบ

1. **ข้อความเดียวกัน** — ถ้าแยก ผู้โจมตีจะใช้ endpoint นี้ไล่หาว่าอีเมลไหนมีในระบบ
2. **เวลาเท่ากัน** — ต้องรัน argon2id verify แม้หาอีเมลไม่เจอ ด้วย hash ปลอมที่ cost เท่ากัน
   ไม่งั้นเวลาตอบกลับจะบอกคำตอบแทนข้อความ (ดู `DUMMY_ARGON2ID` ใน `auth.service.ts`)

---

## เริ่มยังไง

```bash
# 1 · สร้างฐานข้อมูล
createdb feat03
psql -d feat03 -v ON_ERROR_STOP=1 -f db/migration.sql

# 2 · พิสูจน์ว่า schema ให้สิ่งที่ RFD สัญญาไว้จริง
psql -d feat03 -f tests/acceptance.sql
#    ทุกแถวต้อง PASS · ทั้งไฟล์รันใน transaction เดียวแล้ว ROLLBACK
#    รันซ้ำกี่รอบก็ได้ ไม่ทิ้งข้อมูลไว้

# 3 · entity
export DATABASE_URL="postgresql://localhost/feat03"
npx prisma generate --schema db/schema.prisma
rm -rf typings/                 # ลบ stub ทิ้งหลัง generate
#    แล้วเอา "paths" ออกจาก tsconfig.json

# 4 · type check
npx tsc -p tsconfig.json
```

---

## กฎที่ฝังอยู่ใน schema แล้ว · ไม่ต้องพึ่งโค้ด

| กฎ | บังคับด้วย |
|---|---|
| token ใบหนึ่งหมุนได้ครั้งเดียว | `uq_session_parent` partial unique index |
| refresh token ค่าเดียวกันเกิดสองแถวไม่ได้ | `uq_session_token` |
| session ต้องมีเจ้าของคนเดียว | `CHECK (num_nonnulls(merchant_admin_id, customer_id) = 1)` |
| `subject_kind` ต้องตรงกับคอลัมน์ที่มีค่า | `ck_subject_matches` |
| เพิกถอนต้องบอกเหตุผลเสมอ | `ck_revoke_has_reason` |
| วันหมดอายุต้องอยู่หลังวันสร้าง | `ck_expiry_after_create` |
| password ต้องเป็น argon2id | `CHECK (password_hash LIKE '$argon2id$%')` |
| บันทึก login สำเร็จต้องไม่มีรหัสความล้มเหลว | `ck_failure_code` |

**T7 กับ T8 ตรวจโครงสร้างตาราง ไม่ใช่ข้อมูล** — ยืนยันว่าไม่มีคอลัมน์ไหนในระบบ
เก็บ token แบบ plaintext และไม่มีตารางไหนเก็บ access token เลย
ถ้าวันหนึ่งมีคนเผลอเพิ่มเข้ามา test จะแดงทันที

---

## ผลการตรวจ

| สิ่งที่ตรวจ | ด้วยอะไร | ผล |
|---|---|---|
| `db/migration.sql` | รันบน PostgreSQL 16.13 จริง | 7 ตาราง · 18 index · ผ่าน |
| `tests/acceptance.sql` | รันบนฐานข้อมูลเดียวกัน | **PASS 15 · FAIL 0** |
| `api/openapi.yaml` | `openapi-spec-validator` | valid · 4 path · 6 schema · 10 response |
| `db/schema.prisma` | เทียบกับ `information_schema` ของ DB จริง | 7/7 ตาราง ตรง · ไม่มีคอลัมน์หลุด |
| `src/*.ts` | `tsc --strict --noUncheckedIndexedAccess` | 0 error |
| `diagrams/*.mmd` | render ด้วย mermaid จริง | 3/3 ผ่าน |

---

## 15 ข้อรับประกันที่ test พิสูจน์

| # | ข้อ |
|---|---|
| T1 | refresh token ค่าเดียวกันเกิดสองแถวไม่ได้ |
| T2 | หมุน refresh token ใบเดิมซ้ำ → ถูกฐานข้อมูลปฏิเสธ |
| T3 | เพิกถอนทั้ง family → ไม่เหลือ session ที่ยังใช้ได้เลย |
| T4 | ตั้ง `revoked_at` โดยไม่ใส่ `revoked_reason` → ถูกปฏิเสธ |
| T5 | session ที่มีเจ้าของสองคน หรือไม่มีเจ้าของเลย → ถูกปฏิเสธ |
| T6 | `subject_kind` ไม่ตรงกับคอลัมน์ที่มีค่า → ถูกปฏิเสธ |
| T7 | `auth_session` ไม่มีคอลัมน์เก็บ token แบบ plaintext เลย |
| T8 | ไม่มีตารางไหนเก็บ access token |
| T9 | session ที่หมดอายุก่อนถูกสร้าง → ถูกปฏิเสธ |
| T10 | password ที่เป็น bcrypt หรือ plaintext เข้าฐานข้อมูลไม่ได้ |
| T11 | บันทึก login สำเร็จพร้อมรหัสความล้มเหลว → ถูกปฏิเสธ |
| T12 | `login_attempt` เก็บแต่ hash ไม่เก็บอีเมลหรือ IP ตรงๆ |
| T13 | นับครั้งที่พลาดใน 15 นาทีแล้วล็อกบัญชีได้ |
| T14 | ไม่มี session ที่ยังใช้ได้ของบัญชีที่ถูกปิด |
| T15 | สายที่เจอการใช้ซ้ำ ไม่มีใบลูกที่ยังใช้ได้เหลืออยู่ |

---

## สิ่งที่ feature นี้แก้จากระบบเดิม

| ปัญหาเดิม | แก้ด้วย |
|---|---|
| F9 · endpoint สำคัญเป็น `@Public()` ไม่มี guard | ทุก endpoint ต้องมี `bearerAuth` ยกเว้น login |
| F12 · `bcrypt(10)` | argon2id · บังคับด้วย `CHECK` ไม่ใช่ convention |
| F12 · register คืน 201 โดยไม่มี token | ถูกแล้ว · ล็อกอินเป็นขั้นแยก (ยืนยันใน RFD 16) |

---

## ยังไม่ได้ทำในชุดนี้

1. **ฝั่ง customer** — schema รองรับแล้ว (`customer_id` ใน `auth_session`) แต่ `auth.service.ts`
   เขียนเฉพาะเส้นทางของ `merchant_admin` · ลูกค้าล็อกอินด้วย OTP ซึ่งอยู่ใน FEAT-02
2. **การเซ็น JWT จริง** — `TokenSigner` เป็น interface ยังไม่มี implementation
   และยังไม่ได้ตัดสินว่าใช้ ES256 หรือ EdDSA และเก็บ key ที่ไหน
3. **`PLATFORM_ADMIN`** — enum มีแล้ว แต่ยังไม่มี flow
4. **การหมุน signing key ของ JWT** — ต้องมี `kid` และรองรับสอง key พร้อมกันช่วง rotate
5. **unit test ฝั่ง TypeScript** — มีแต่ test ระดับ schema

---

## อ้างอิง

| เอกสาร | ส่วนที่เกี่ยวข้อง |
|---|---|
| RFD 16 | Auth & Authorization · §3.3 §3.4 · D6 |
| RFD 8 | Identity · D7 argon2id |
| RFD 3 | Idempotency · D1 · `scopeOf()` |
| FEAT-01 | `merchant`, `merchant_admin` มาจากชุดนั้น |
| `api-spec-v1` | §1 conventions |
| `data-model-v1` | Group A |
