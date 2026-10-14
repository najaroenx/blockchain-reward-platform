# FEAT-07 · Create Coupon Type + Issue Codes · dev pack

ร้านสร้างประเภทคูปอง แล้วออกรหัสเป็นชุด

```text
pack07/
├── api/openapi.yaml         OpenAPI 3.1 · validate ผ่าน
├── db/migration.sql         DDL · รันบน PostgreSQL 16 จริงแล้ว
├── db/schema.prisma         entity · ตรงกับ DB ทุกคอลัมน์
├── src/types.ts             type + การสร้างรหัส · tsc strict ผ่าน
├── src/coupon.service.ts    ชั้น ADMIT ของทั้งสอง endpoint
├── tests/acceptance.sql     23 ข้อรับประกัน · PASS 23 FAIL 0
└── diagrams/                sequence · ER · state
```

---

## เรื่องสำคัญที่สุด · รหัสคูปองไม่เคยถูกเก็บลงฐานข้อมูล

| สิ่งที่เก็บ | คืออะไร | ใช้ทำอะไร |
|---|---|---|
| `code_hash` | `sha256(plaintext)` | ค้นหาตอนลูกค้ายื่นรหัสมา |
| `code_ref` | `sha256(id)` | ส่งขึ้น chain |
| plaintext | **ไม่เก็บ** | คืนครั้งเดียวตอนออก |

plaintext อยู่ในตัวแปรของ request นั้นแล้วออกไปกับ response ครั้งเดียว
ไม่มีที่ไหนในระบบเก็บไว้ — ไม่ใช่แค่ไม่ใส่ตาราง แต่รวมถึง

```ts
payload: { couponTypeId, quantity }     // operation · ไม่มีรหัส
payload: { batchId, couponTypeId }      // outbox · ไม่มีรหัส
responseBody: { ..., codes: [] }        // idempotency replay · ไม่มีรหัส
```

ถ้าใส่ลง `operation.payload` มันจะไปโผล่ใน log · ถ้าใส่ลง `responseBody`
การ retry ด้วย Idempotency-Key เดิมจะส่งรหัสออกไปอีกครั้ง ซึ่งขัดกับ "ส่งครั้งเดียว"

**T10 ตรวจโครงสร้างตาราง** ว่าไม่มีคอลัมน์ไหนใน `coupon_code` ที่ชื่อสื่อถึงรหัส
นอกจาก `code_hash` กับ `code_ref`

---

## ทำไม `code_ref` ไม่ใช่ hash ของ plaintext

เหตุผลไม่ใช่เรื่องความลับ (plaintext มี entropy 60 บิต brute force ไม่คุ้มอยู่แล้ว)
เหตุผลคือ **ใครคำนวณค่านี้ได้บ้าง**

```text
api        เห็น plaintext       ตอนออกรหัสเท่านั้น
worker     ไม่เคยเห็น plaintext
indexer    ไม่เคยเห็น plaintext
projector  ไม่เคยเห็น plaintext
```

ถ้า `code_ref` มาจาก plaintext · worker จะสร้าง tx ไม่ได้ และ projector
จะจับคู่ event บน chain กลับมาหาแถวในฐานข้อมูลไม่ได้

ใช้ `sha256(id)` แทน → ทุกฝ่ายคำนวณค่าเดียวกันได้จาก `id` ที่ทุกคนเห็นอยู่แล้ว

```sql
CREATE TRIGGER trg_code_ref_derived BEFORE INSERT OR UPDATE ON coupon_code ...
  IF NEW.code_ref <> sha256(convert_to(NEW.id, 'UTF8')) THEN RAISE ...
```

**ตรวจข้ามภาษาแล้ว** — `codeRefOf()` ใน TypeScript ให้ผลตรงกับ
`sha256(convert_to(id,'UTF8'))` ใน SQL ทุกกรณีที่ทดสอบ รวมถึง id ที่มีอักษรไทย

```text
cc_a1b2c3d4e5f6   ตรงกัน
cc_ทดสอบ          ตรงกัน
cc_zzz            ตรงกัน
```

---

## โควตาตัดสินด้วย trigger ไม่ใช่ `SELECT` มานับก่อน

```sql
PERFORM pg_advisory_xact_lock(hashtextextended(NEW.coupon_type_id, 1));
SELECT count(*) INTO v_issued FROM coupon_code
 WHERE coupon_type_id = NEW.coupon_type_id AND state <> 'VOIDED';
IF v_issued >= v_supply THEN RAISE ...
```

`SELECT count(*)` แล้วค่อย `INSERT` ในโค้ด จะมีช่องให้คำขออื่นแทรกเสมอ
trigger ล็อกเฉพาะประเภทนั้นจนจบ transaction จึงนับได้ถูกต้องโดยไม่กันประเภทอื่น

**`VOIDED` ปล่อยโควตาคืน** — `state <> 'VOIDED'` ใน trigger ทำให้ร้านที่ยกเลิก
ใบหนึ่งออกใบใหม่แทนได้ โดยไม่ต้องลบแถว ประวัติยังอยู่ครบ

```text
T7  ออกครบ 3 ใบตาม supply · ใบที่ 4 → ถูกปฏิเสธ
T8  ยกเลิกใบหนึ่งแล้วออกใบใหม่ได้
T21 invariant · ไม่มีประเภทไหนที่ออกเกิน supply
```

---

## การสร้างรหัส

```ts
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'   // ไม่มี I L O U
```

Crockford base32 · ตัด `I` `L` `O` `U` ออกเพราะคนอ่านสับสนกับ `1` `0`
12 ตัวอักษร = 60 บิตของ entropy ต่อหนึ่งรหัส

ใช้ rejection sampling แทน `% 32` ตรงๆ เพื่อไม่ให้ตัวอักษรบางตัวมีโอกาสออกมากกว่าตัวอื่น
(กรณีนี้ 256 หารด้วย 32 ลงตัวพอดี แต่เขียนให้ชัดไว้ ถ้าวันหนึ่งเปลี่ยน alphabet จะไม่พลาด)

รหัสชนกันถูกจับด้วย `uq_code_hash` ที่ unique **ทั้งระบบ** ไม่ใช่แค่ในประเภทเดียวกัน
— ลูกค้ายื่นรหัสมาโดยไม่บอกว่าเป็นของประเภทไหน ระบบต้องหาเจอจากรหัสอย่างเดียว

---

## ทำไม `202` ไม่ใช่ `201`

ทั้งสอง endpoint คืน `202` เพราะทั้งคู่ต้องจบบน chain

แต่ **การออกรหัสคืนข้อมูลที่มีค่าจริงมาแล้วใน `202`** นั่นคือตัวรหัส
ซึ่งใช้ได้ทันทีในระดับฐานข้อมูล · ส่วน `mintCoupon` บน chain คือการทำให้
คูปองพวกนั้นมีตัวตนบน chain เพื่อซื้อขายต่อได้ (FEAT-12)

---

## เริ่มยังไง

```bash
# 1 · สร้างฐานข้อมูล
createdb feat07
psql -d feat07 -v ON_ERROR_STOP=1 -f db/migration.sql

# 2 · พิสูจน์ว่า schema ให้สิ่งที่ RFD สัญญาไว้จริง
psql -d feat07 -f tests/acceptance.sql
#    ทุกแถวต้อง PASS · รันซ้ำกี่รอบก็ได้ ไม่ทิ้งข้อมูลไว้

# 3 · entity
export DATABASE_URL="postgresql://localhost/feat07"
npx prisma generate --schema db/schema.prisma
rm -rf typings/                 # ลบ stub ทิ้งหลัง generate

# 4 · type check
npx tsc -p tsconfig.json
```

---

## กฎที่ฝังอยู่ใน schema แล้ว · ไม่ต้องพึ่งโค้ด

| กฎ | บังคับด้วย |
|---|---|
| `code_ref` ต้องเท่ากับ `sha256(id)` เสมอ | trigger `trg_code_ref_derived` |
| ออกรหัสเกิน `total_supply` ไม่ได้ | trigger `trg_issue_within_supply` + advisory lock |
| ร้านที่ยังไม่ `ACTIVE` สร้างประเภทไม่ได้ | trigger `trg_coupon_type_merchant_active` |
| ค่าที่มาจาก chain แก้ไม่ได้หลังเขียน | trigger `trg_coupon_chain_immutable` |
| รหัสซ้ำกันทั้งระบบไม่ได้ | `uq_code_hash` · `uq_code_ref` |
| ชื่อประเภทซ้ำในร้านเดียวไม่ได้ | `uq_coupon_type_name` (ยกเว้น `FAILED`) |
| `HELD` ต้องมีผู้ถือ | `CHECK (state <> 'HELD' OR holder_id IS NOT NULL)` |
| ผู้ถือต้องระบุทั้งชนิดและรหัส | `CHECK ((holder_kind IS NULL) = (holder_id IS NULL))` |
| `REDEEMED` ต้องมีเวลาที่ใช้ | `CHECK ((state = 'REDEEMED') = (redeemed_at IS NOT NULL))` |
| วันหมดอายุต้องหลังวันสร้าง | `ck_coupon_type_expiry` |
| step ละไม่เกิน 500 ใบ | `CHECK (mint_count BETWEEN 1 AND 500)` |

---

## ผลการตรวจ

| สิ่งที่ตรวจ | ด้วยอะไร | ผล |
|---|---|---|
| `db/migration.sql` | รันบน PostgreSQL 16.13 จริง | 12 ตาราง · 28 index · 5 trigger · ผ่าน |
| `tests/acceptance.sql` | รันบนฐานข้อมูลเดียวกัน | **PASS 23 · FAIL 0** |
| `api/openapi.yaml` | `openapi-spec-validator` | valid · 3 path · 14 schema · 10 response |
| `db/schema.prisma` | เทียบกับ `information_schema` ของ DB จริง | 12/12 ตาราง ตรง · ไม่มีคอลัมน์หลุด |
| `src/*.ts` | `tsc --strict --noUncheckedIndexedAccess` | 0 error |
| **`codeRefOf()` TS เทียบกับ SQL** | รันทั้งสองฝั่งแล้วเทียบ hex | ตรงกัน 3/3 รวมอักษรไทย |
| `diagrams/*.mmd` | render ด้วย mermaid จริง | 3/3 ผ่าน |

---

## 23 ข้อรับประกันที่ test พิสูจน์

| # | ข้อ |
|---|---|
| T1 | ออกคูปองซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows |
| T2 | ร้านที่ `status` ยังไม่ `ACTIVE` สร้างประเภทคูปองไม่ได้ |
| T3 | ชื่อประเภทคูปองซ้ำในร้านเดียว → ถูกปฏิเสธ |
| T4 | deploy ล้มแล้วใช้ชื่อเดิมสร้างใหม่ได้ |
| T5 | วันหมดอายุก่อนวันสร้าง หรือ supply เป็น 0 → ถูกปฏิเสธ |
| T6 | `code_ref` ที่ไม่ใช่ `sha256(id)` → ถูกปฏิเสธ |
| T7 | ออกครบ 3 ใบตาม supply · ใบที่ 4 → ถูกปฏิเสธ |
| T8 | ยกเลิกใบหนึ่งแล้วออกใบใหม่ได้ · `VOIDED` ปล่อยโควตาคืน |
| T9 | รหัสชนกันข้ามประเภทคูปอง → ถูกปฏิเสธ |
| T10 | `coupon_code` ไม่มีคอลัมน์เก็บรหัสแบบ plaintext เลย |
| T11 | `HELD` โดยไม่มีผู้ถือ หรือ `REDEEMED` โดยไม่มีเวลา → ถูกปฏิเสธ |
| T12 | ใส่ `holder_kind` โดยไม่ใส่ `holder_id` → ถูกปฏิเสธ |
| T13 | แก้ `chain_type_id` ของประเภทที่ deploy แล้ว → ถูกปฏิเสธ |
| T14 | contract address + `chain_type_id` ซ้ำ → ถูกปฏิเสธ |
| T15 | สั่ง deploy ประเภทคูปองเดิมซ้อนกัน → ถูกปฏิเสธ |
| T16 | mint 1200 ใบ = 3 step · step ที่เกิน 500 → ถูกปฏิเสธ |
| T17 | เปลี่ยน step เป็น `SUBMITTED` โดยไม่มี `raw_tx` → ถูกปฏิเสธ |
| T18 | ใช้ `nonce` เดิมของ signer ตัวเดิมซ้ำ → ถูกปฏิเสธ |
| T19 | เก็บ `face_value` เป็น uint256 สูงสุดได้ครบทุกหลัก |
| T20 | ไม่มีประเภทคูปองที่ `LIVE` แต่ยังไม่มี contract |
| T21 | ไม่มีประเภทไหนที่ออกรหัสเกิน supply ที่ประกาศไว้ |
| T22 | ไม่มี `operation` ที่ไม่มี `outbox` คู่กัน |
| T23 | อ่าน log ช่วงเดิมซ้ำ → `chain_event` ไม่เกิดแถวซ้ำ |

---

## สิ่งที่ feature นี้แก้จากระบบเดิม

| ปัญหาเดิม | แก้ด้วย |
|---|---|
| F3 · `contract.redeem(typeId, amount)` burn ตามประเภทและจำนวน chain ไม่รู้ว่าใบไหนถูกใช้ | `code_ref` ต่อใบ ส่งขึ้น chain ตั้งแต่ตอน mint · projector จับคู่กลับได้ |

ข้อนี้คือสิ่งที่ทำให้ FEAT-11 (redeem) มี projection ที่ replay ได้
ถ้าไม่มี `code_ref` ต่อใบ การ rebuild จะบอกไม่ได้ว่าใบไหนถูกใช้ไปแล้ว

---

## ยังไม่ได้ทำในชุดนี้

1. **worker** — มีชั้น ADMIT · การเซ็นและ broadcast ยังไม่มีโค้ด
2. **ABI ของ contract** — `createCouponType(...)` และ `mintCoupon(chainTypeId, codeRef[])`
   เป็นข้อกำหนดที่ contract ต้องมี ยังไม่มีของจริง (RFD 11 Q2)
3. **การแจกคูปองให้ลูกค้า** — `ISSUED → HELD` ยังไม่มี endpoint
4. **`RETIRED`** — enum มีแล้ว ยังไม่มี endpoint
5. **การหมดอายุอัตโนมัติ** — `EXPIRED` ควรเป็นค่าที่คำนวณตอน query เหมือน FEAT-06
   ไม่ใช่สถานะที่ต้องมีใครไปเขียน · ยังไม่ได้ทำให้เป็นแบบนั้น
6. **unit test ฝั่ง TypeScript** — มีแต่ test ระดับ schema

---

## อ้างอิง

| เอกสาร | ส่วนที่เกี่ยวข้อง |
|---|---|
| RFD 2 | Write Path · R1 R2 D1 D4 D9 |
| RFD 3 | Idempotency · D1 |
| RFD 11 | Coupon Lifecycle · §3.2 state machine · **§3.3 `code_hash` กับ `code_ref`** |
| RFD 14 | Money · `face_value` เป็น base units |
| FEAT-01 | ร้านต้อง `ACTIVE` ก่อน |
| FEAT-11 | redeem ใช้ `code_hash` ค้นหา และ `code_ref` จับคู่ event |
| `data-model-v1` | Group A · Group B |
