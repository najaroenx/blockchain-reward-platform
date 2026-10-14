# FEAT-01 · Merchant Onboarding · dev pack

สมัครร้านค้า แล้ว provision wallet บน chain เป็นงานแยกที่ตามมาทีหลัง

```text
pack01/
├── api/openapi.yaml            OpenAPI 3.1 · validate ผ่าน
├── db/migration.sql            DDL · รันบน PostgreSQL 16 จริงแล้ว
├── db/schema.prisma            entity · ตรงกับ DB ทุกคอลัมน์
├── src/types.ts                type ที่ใช้ร่วมกัน · tsc strict ผ่าน
├── src/onboarding.service.ts   ชั้น ADMIT · โครงที่ต่อได้ทันที
├── tests/acceptance.sql        14 ข้อรับประกัน · PASS 14 FAIL 0
└── diagrams/                   sequence · ER · state
```

---

## การตัดสินใจที่สำคัญที่สุดของ feature นี้ · `201` ไม่ใช่ `202`

ไล่ดูทีละอย่างว่าตอนสมัครมีอะไรต้องทำบน chain จริงบ้าง

| ขั้นตอน | เป็น tx บน chain ไหม |
|---|---|
| สร้าง key ที่ KMS | ไม่ · เป็น API call ธรรมดา |
| คำนวณ address จาก public key | ไม่ · คำนวณได้ทันที |
| `whitelistMerchant` | ใช่ |
| `setApprovalForAll` ให้ marketplace | ใช่ |

สองอย่างแรกจบใน request ได้ · สองอย่างหลัง **ไม่จำเป็นต้องเสร็จก่อนร้านมีตัวตน**

จึงคืน `201` พร้อม `merchantId` และ `wallet.address` ทันที แล้วแยก provision เป็น `operation`
ที่ commit พร้อมกันใน transaction เดียว · ร้านล็อกอินและแก้โปรไฟล์ได้เลยโดยไม่ต้องรอ chain

**เงื่อนไขสองข้อที่ทำให้ `201` ไม่เป็นคำโกหก**

1. `merchant.status` เป็น `PENDING` · `ACTIVE` เขียนได้จาก projector เท่านั้น
2. endpoint ที่ต้องใช้ chain ตอบ `422 MERCHANT_WALLET_NOT_READY` จนกว่า provision จะ `FINALIZED`

---

## ลำดับที่ห้ามสลับ

```text
1  validate DTO
2  normalize email · NFC → trim → lowercase
3  fingerprint = sha256(canonical DTO)         ← ไม่มี salt ไม่มี HMAC
4  argon2id hash password                      ← หลักร้อย ms
5  KMS createKey                               ← network call
   ─────────────────── BEGIN ───────────────────
6  INSERT idempotency_key ON CONFLICT DO NOTHING   ← สเตตเมนต์แรกเสมอ
7  merchant → merchant_admin → wallet
8  operation → operation_step ×2 → outbox → operation_event
9  UPDATE idempotency_key SET response 201
   ─────────────────── COMMIT ──────────────────
10 ตอบ 201
```

**ข้อ 4 กับ 5 อยู่นอก transaction** เพราะ argon2id กินเวลา และ KMS เป็น external call
ถือ DB transaction ค้างระหว่างรอ network คือ outage ที่รอเวลาเกิด (RFD 4 D3)

ราคาที่จ่ายคือ ถ้าพังหลังข้อ 5 จะเหลือ key กำพร้าใน KMS — ยอมรับได้
key ที่ไม่มีใครใช้ไม่ทำให้ระบบผิด ตรงข้ามกับร้านที่ไม่มี key

---

## เริ่มยังไง

```bash
# 1 · สร้างฐานข้อมูล
createdb feat01
psql -d feat01 -v ON_ERROR_STOP=1 -f db/migration.sql

# 2 · พิสูจน์ว่า schema ให้สิ่งที่ RFD สัญญาไว้จริง
psql -d feat01 -f tests/acceptance.sql
#    ทุกแถวต้อง PASS · ทั้งไฟล์รันใน transaction เดียวแล้ว ROLLBACK
#    รันซ้ำกี่รอบก็ได้ ไม่ทิ้งข้อมูลไว้

# 3 · entity
export DATABASE_URL="postgresql://localhost/feat01"
npx prisma generate --schema db/schema.prisma
rm -rf typings/                 # ลบ stub ทิ้งหลัง generate
#    แล้วเอา "paths" ออกจาก tsconfig.json

# 4 · type check
npx tsc -p tsconfig.json
```

---

## กฎที่ฝังอยู่ใน schema แล้ว · ไม่ต้องพึ่งโค้ด

| กฎ | บังคับด้วย | ที่มา |
|---|---|---|
| `wallet` ไม่มีคอลัมน์ private key | ไม่มีคอลัมน์นั้นอยู่จริง · T3 ตรวจโครงสร้างตาราง | RFD 4 L6 |
| password ต้องเป็น argon2id | `CHECK (password_hash LIKE '$argon2id$%')` | RFD 8 D7 |
| อีเมลเดียวกันที่พิมพ์ต่างกัน สมัครซ้ำไม่ได้ | `uq_admin_email` บน `email_normalized` | RFD 8 §3.3 |
| ร้าน `ACTIVE` ต้องมี `activated_at` | `ck_merchant_active` | RFD 8 §3.4 |
| ร้านหนึ่งมีงาน provision ค้างทีละงานเดียว | `uq_provision_inflight` partial unique index | — |
| `topic` ต้องมีเวอร์ชันต่อท้าย | `CHECK (topic ~ '\.v[0-9]+$')` | RFD 7 D9 |
| `nonce` ของ signer ตัวหนึ่งใช้ซ้ำไม่ได้ | `uq_signer_nonce` | RFD 4 §3.6 |
| broadcast ไม่ได้ถ้า `raw_tx` ยังไม่ลงตาราง | `ck_rawtx_before_broadcast` | RFD 2 R2 |

**T3 น่าสนใจเป็นพิเศษ** — มันไม่ได้ตรวจข้อมูล แต่ query `information_schema` เพื่อยืนยันว่า
ตาราง `wallet` ไม่มีคอลัมน์ชื่อไหนเลยที่สื่อถึง private key, secret, mnemonic, seed หรือ cipher
ถ้าวันหนึ่งมีคนเผลอเพิ่มคอลัมน์แบบนั้น test จะแดงทันที

---

## ผลการตรวจ

| สิ่งที่ตรวจ | ด้วยอะไร | ผล |
|---|---|---|
| `db/migration.sql` | รันบน PostgreSQL 16.13 จริง | 11 ตาราง · 26 index · ผ่าน |
| `tests/acceptance.sql` | รันบนฐานข้อมูลเดียวกัน | **PASS 14 · FAIL 0** |
| `api/openapi.yaml` | `openapi-spec-validator` | valid · 3 path · 11 schema · 9 response |
| `db/schema.prisma` | เทียบกับ `information_schema` ของ DB จริง | 11/11 ตาราง ตรง · ไม่มีคอลัมน์หลุด |
| `src/*.ts` | `tsc --strict --noUncheckedIndexedAccess` | 0 error |
| `diagrams/*.mmd` | render ด้วย mermaid จริง | 3/3 ผ่าน |

---

## 14 ข้อรับประกันที่ test พิสูจน์

| # | ข้อ |
|---|---|
| T1 | กดสมัครซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows ไม่ throw |
| T2 | อีเมลเดียวกันที่พิมพ์ตัวใหญ่หรือมีช่องว่าง → ถูกปฏิเสธ |
| T3 | ตาราง `wallet` ไม่มีคอลัมน์ที่เก็บ private key เลย |
| T4 | password ที่เป็น bcrypt หรือ plaintext เข้าฐานข้อมูลไม่ได้ |
| T5 | ตั้งร้านเป็น `ACTIVE` โดยไม่มี `activated_at` → ถูกปฏิเสธ |
| T6 | สั่ง provision ร้านเดิมซ้อนกัน → ถูกปฏิเสธ |
| T7 | `topic` ที่ไม่มีเวอร์ชันต่อท้าย → ถูกปฏิเสธ |
| T8 | เปลี่ยน step เป็น `SUBMITTED` โดยไม่มี `raw_tx` → ถูกปฏิเสธ |
| T9 | ใช้ `nonce` เดิมของ signer ตัวเดิมซ้ำ → ถูกปฏิเสธ |
| T10 | ส่ง `raw_tx` ไบต์เดิมซ้ำ → `tx_hash` ซ้ำถูกปฏิเสธ |
| T11 | ร้านเดิมมี wallet ใบที่สองไม่ได้ · address ซ้ำไม่ได้ |
| T12 | ไม่มี `operation` ที่ไม่มี `outbox` คู่กัน |
| T13 | ไม่มีร้านที่ `ACTIVE` แต่ยังไม่มี wallet |
| T14 | อ่าน log ช่วงเดิมซ้ำ → `chain_event` ไม่เกิดแถวซ้ำ |

---

## สิ่งที่ feature นี้แก้จากระบบเดิม

| ปัญหาเดิม | แก้ด้วย |
|---|---|
| F12 · เก็บ private key ที่เข้ารหัส AES ไว้ใน DB | `wallet` มีแค่ `address` + `key_ref` · key อยู่ใน KMS |
| F12 · `bcrypt(10)` | argon2id · บังคับด้วย `CHECK` ไม่ใช่ convention |
| F2 · ไม่มี idempotency เลยทั้ง repo | `uq_idem` บน `(scope, key)` · scope ตอนสมัครเป็น `anon:<hash>` |
| F13 · `wallet` เก็บ key ที่เข้ารหัสไว้ในฐานข้อมูล | T3 ทำให้คอลัมน์แบบนั้นเพิ่มเข้ามาไม่ได้โดยไม่มีใครรู้ |

---

## ยังไม่ได้ทำในชุดนี้

1. **worker** — ชุดนี้มีแค่ชั้น ADMIT ของ api · การเซ็น broadcast และ projector ยังไม่มีโค้ด
2. **ABI ของ contract ใหม่** — `whitelistMerchant` เป็นข้อกำหนดที่ contract ต้องมี ยังไม่มีของจริง
3. **การยืนยันอีเมล** — สมัครแล้วใช้ได้เลย ยังไม่มีขั้นยืนยัน
4. **`N` block ที่ถือว่า final** — ยังไม่มีใครตัดสิน (RFD 1 Q1)
5. **unit test ฝั่ง TypeScript** — มีแต่ test ระดับ schema

---

## อ้างอิง

| เอกสาร | ส่วนที่เกี่ยวข้อง |
|---|---|
| RFD 2 | Write Path · R1 R2 D1 D4 D9 |
| RFD 3 | Idempotency · D1 D6 · scope แบบ anon |
| RFD 4 | Key Management · L5 L6 D3 · §3.5 §3.6 |
| RFD 7 | Deployment · D9 topic versioning |
| RFD 8 | Identity & Onboarding · §3.2 §3.3 §3.4 · D7 |
| `api-spec-v1` | §1 conventions · §2 Identity |
| `data-model-v1` | Group A · Group B |
