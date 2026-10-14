# FEAT-11 · Redeem Coupon · dev pack

ชุดที่ dev หยิบไปเริ่มเขียนโค้ดได้เลย · ทุกไฟล์ถูกรันหรือ validate จริงแล้ว ไม่ใช่ตัวอย่างลอยๆ

```text
pack/
├── api/openapi.yaml          OpenAPI 3.1 · validate ผ่าน
├── db/migration.sql          DDL · รันบน PostgreSQL 16 จริงแล้ว
├── db/schema.prisma          entity · ตรงกับ DB ทุกคอลัมน์
├── src/types.ts              type ที่ใช้ร่วมกัน · tsc strict ผ่าน
├── src/redeem.service.ts     ชั้น ADMIT · โครงที่ต่อได้ทันที
├── tests/acceptance.sql      12 ข้อรับประกัน · PASS 12 FAIL 0
└── diagrams/                 sequence · ER · state
```

---

## สิ่งที่ feature นี้ทำ

ลูกค้าใช้คูปองหนึ่งใบ · ระบบ burn บน chain แล้วปล่อยเงินจาก escrow ให้ผู้ขาย

**เป็น operation ที่มี 2 step บน chain** และลำดับห้ามสลับ

| step | contract | ถ้าล้ม |
|---|---|---|
| 1 · `burnCoupon` | `Coupon` | ยังไม่มีอะไรเสียหาย · ลองใหม่ได้ |
| 2 · `releaseFundsPartial` | `Vault` | burn ไปแล้ว · เข้า `MANUAL_REVIEW` เงินยังค้างใน vault ที่กู้ได้ |

เหตุที่ burn ก่อน release — ถ้าสลับลำดับ เงินออกไปแล้วแต่คูปองยังใช้ได้ ซึ่งกู้ไม่ได้

---

## เริ่มยังไง

```bash
# 1 · สร้างฐานข้อมูล
createdb feat11
psql -d feat11 -v ON_ERROR_STOP=1 -f db/migration.sql

# 2 · พิสูจน์ว่า schema ให้สิ่งที่ RFD สัญญาไว้จริง
psql -d feat11 -f tests/acceptance.sql
#    ทุกแถวต้อง PASS · แถวเดียวที่ FAIL = schema ไม่ครบ
#    ทั้งไฟล์รันใน transaction เดียวแล้ว ROLLBACK · รันซ้ำกี่รอบก็ได้ ไม่ทิ้งข้อมูลไว้

# 3 · entity
export DATABASE_URL="postgresql://localhost/feat11"
npx prisma generate --schema db/schema.prisma
rm -rf typings/                      # ลบ stub ทิ้งหลัง generate
#    แล้วเอา "paths" ออกจาก tsconfig.json

# 4 · type check
npx tsc -p tsconfig.json
```

> `typings/@prisma/client.d.ts` เป็น **ตัวแทนชั่วคราว** ที่ทำให้ `tsc` ตรวจ `src/` ได้
> ก่อนมีไคลเอนต์จริง · หลัง `prisma generate` ให้ลบทิ้งตามขั้นที่ 3

---

## กฎที่ฝังอยู่ใน schema แล้ว · ไม่ต้องพึ่งโค้ด

สี่ข้อนี้คือเหตุผลที่ feature นี้ไม่ซ้ำรอยระบบเดิม

| กฎ | บังคับด้วย | ที่มา |
|---|---|---|
| คูปองใบเดียวถูกใช้ซ้ำไม่ได้ | `uq_reservation_exclusive` partial unique index | RFD 11 D4 |
| ส่ง request ซ้ำไม่เกิดงานใหม่ | `uq_idem` บน `(scope, key)` | RFD 3 D1 |
| broadcast ไม่ได้ถ้า `raw_tx` ยังไม่ลงตาราง | `ck_rawtx_before_broadcast` | RFD 2 R2 |
| `tx_hash` เดียวกันเกิดสองแถวไม่ได้ | `uq_step_txhash` | RFD 2 D4 |

**ความต่างที่สำคัญ** — ระบบเดิมเช็ค `isUsed` ด้วย `if` ในโค้ด แล้วมีช่องว่าง 283 บรรทัดระหว่างอ่านกับเขียน
ชุดนี้ไม่เช็คด้วย `if` เลย · การจองซ้ำถูกฐานข้อมูลปฏิเสธตั้งแต่ `INSERT` โค้ดจะพลาดยังไงก็ทะลุไม่ได้

---

## ผลการตรวจ

| สิ่งที่ตรวจ | ด้วยอะไร | ผล |
|---|---|---|
| `db/migration.sql` | รันบน PostgreSQL 16.13 จริง | 14 ตาราง · 34 index · ผ่าน |
| `tests/acceptance.sql` | รันบนฐานข้อมูลเดียวกัน สองรอบติด | **PASS 12 · FAIL 0** ทั้งสองรอบ · ไม่ทิ้งแถวไว้ |
| `api/openapi.yaml` | `openapi-spec-validator` | valid · 2 path · 8 schema · 9 response |
| `db/schema.prisma` | เทียบกับ `information_schema` ของ DB จริง | 14/14 ตาราง ตรง · ไม่มีคอลัมน์หลุด |
| `src/*.ts` | `tsc --strict --noUncheckedIndexedAccess` | 0 error |
| `diagrams/*.mmd` | render ด้วย mermaid จริง | 3/3 ผ่าน |

---

## 12 ข้อรับประกันที่ test พิสูจน์

| # | ข้อ |
|---|---|
| T1 | ส่ง Idempotency-Key เดิมซ้ำ → แถวที่สองได้ 0 rows ไม่ throw |
| T2 | จอง coupon ใบเดียวกันสองครั้ง → ครั้งที่สองถูกฐานข้อมูลปฏิเสธ |
| T3 | ปล่อยจองแล้วจองใหม่ได้ · ประวัติแถวเดิมยังอยู่ |
| T4 | เปลี่ยน step เป็น `SUBMITTED` โดยไม่มี `raw_tx` → ถูกปฏิเสธ |
| T5 | ส่ง `raw_tx` ไบต์เดิมซ้ำ → `tx_hash` ซ้ำถูกปฏิเสธ ไม่เกิดแถวซ้ำ |
| T6 | อ่าน log ช่วงเดิมซ้ำ → `chain_event` ไม่เกิดแถวซ้ำ |
| T7 | เก็บ uint256 สูงสุด (2^256−1) ได้ครบทุกหลัก |
| T8 | ยอดเงินติดลบถูกปฏิเสธที่ระดับฐานข้อมูล |
| T9 | เปิด escrow ซ้อนบน `tokenId` เดิม → ถูกปฏิเสธ |
| T10 | ไม่มี `operation` ที่ไม่มี `outbox` คู่กัน |
| T11 | ไม่มีคูปองที่ burn แล้วแต่ผู้ขายยังไม่ได้เงิน |
| T12 | `state = REDEEMED` โดยไม่มี `redeemed_at` → ถูกปฏิเสธ |

---

## ยังไม่ได้ทำในชุดนี้

เขียนไว้ตรงๆ เพื่อไม่ให้เข้าใจผิดว่าพร้อม production

1. **worker** — ชุดนี้มีแค่ชั้น ADMIT ของ api · การเซ็น broadcast และ projector ยังไม่มีโค้ด
2. **ABI ของ contract ใหม่** — `burnCoupon(code_ref)` เป็นข้อกำหนดที่ contract ต้องมี ยังไม่มีของจริง (RFD 11 Q2)
3. **`N` block ที่ถือว่า final** — ยังไม่มีใครตัดสิน (RFD 1 Q1)
4. **unit test ฝั่ง TypeScript** — มีแต่ test ระดับ schema
5. **การแบ่งเงินเมื่อหารไม่ลงตัว** — `splitEvenly` เขียนไว้แล้ว แต่ต้องยืนยันว่าตรงกับที่ contract ทำ

---

## อ้างอิง

| เอกสาร | ส่วนที่เกี่ยวข้อง |
|---|---|
| RFD 2 | Write Path · R1 R2 D1 D4 D9 |
| RFD 3 | Idempotency · D1 D6 |
| RFD 11 | Coupon Lifecycle · D4 · §3.3 §3.6 |
| RFD 13 | Escrow · §3.5 §3.6 |
| RFD 14 | Money · D1 D4 D8 |
| RFD 16 | Auth · D4 |
| `api-spec-v1` | §1 conventions · §6 Operation |
| `data-model-v1` | Group A B C D |
