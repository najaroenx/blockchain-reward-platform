# FEAT-08 · List on Marketplace · dev pack

ร้านเอาคูปองที่ถืออยู่ไปลงขายใน marketplace

```text
pack08/
├── api/openapi.yaml          OpenAPI 3.1 · validate ผ่าน
├── db/migration.sql          DDL · รันบน PostgreSQL 16 จริงแล้ว
├── db/schema.prisma          entity · ตรงกับ DB ทุกคอลัมน์
├── src/types.ts              type ที่ใช้ร่วมกัน · tsc strict ผ่าน
├── src/listing.service.ts    ชั้น ADMIT
├── tests/acceptance.sql      25 ข้อรับประกัน · PASS 25 FAIL 0
└── diagrams/                 sequence · ER · state
```

---

## feature นี้คือเหตุผลหลักที่ `operation_step` ต้องมีอยู่

การลงขายหนึ่งครั้งต้องยิงสาม tx ที่ต้องเรียงกัน

| step | ชื่อ | ทำอะไร |
|---|---|---|
| 1 | `approveCoupon` | ให้ marketplace ย้ายคูปองได้ |
| 2 | `createListing` | สร้างรายการขายบน chain |
| 3 | `lockInVault` | ย้ายคูปองเข้า escrow |

ถ้าเก็บ `tx_hash` `nonce` `raw_tx` ไว้บน `operation` แถวเดียว (ซึ่งเป็น design แรก
ที่ RFD 2 §4-F บอกว่าผิด) จะตอบคำถามแรกที่ทุกคนถามเวลามีปัญหาไม่ได้ —
**"ค้างอยู่ขั้นไหน"**

```text
T11  ลงขายมี 3 step เรียง approveCoupon → createListing → lockInVault
T12  step_index ซ้ำในงานเดียวกัน → ถูกปฏิเสธ
```

---

## ของที่ลงขายคือใบที่ระบุเจาะจง ไม่ใช่จำนวน

```json
"couponCodeIds": ["cc_a1b2", "cc_c3d4", "cc_e5f6", "cc_g7h8", "cc_i9j0"]
```

ไม่ใช่ `"quantity": 5` แล้วให้ระบบเลือกเอง

ขาย 5 จาก 10 ใบจึงเป็นเรื่องธรรมดา ไม่ต้องมีกลไกพิเศษ
และ **จำเป็นสำหรับ FEAT-11** เพราะตอน redeem ต้องรู้ว่าเงินก้อนไหนเป็นของใคร
ถ้าลงขายเป็น "จำนวน" ระบบจะบอกไม่ได้ว่าใบที่ลูกค้าเพิ่ง redeem มาจากรายการขายไหน

---

## เงื่อนไขทุกข้ออยู่ในฐานข้อมูล ไม่ใช่ในโค้ด

ระบบเดิมเช็คความเป็นเจ้าของที่ api แล้วมีทางลัดที่ข้ามไปได้ — `delistMarketplaceListing`
เมื่อหา listing ไม่เจอ โค้ดเซ็ต `ownerId = merchantId` เองแล้วทำต่อ (F5)

ชุดนี้ย้ายเงื่อนไขทั้งหมดลง trigger

```sql
CREATE TRIGGER trg_listing_item_valid BEFORE INSERT ON listing_item ...
```

ตรวจทุกใบว่า

1. อยู่ในสถานะ `HELD`
2. อยู่ในมือผู้ขายจริง
3. เป็นประเภทเดียวกับที่ระบุใน listing
4. ยังไม่หมดอายุ

ไม่ว่าจะเรียกผ่าน API, ผ่าน script, หรือ `INSERT` ตรงใน psql ก็ทะลุไม่ได้

```text
T4  ลงขายคูปองของร้านอื่น          → ถูกปฏิเสธที่ฐานข้อมูล
T5  ลงขายใบที่สถานะยังไม่ HELD      → ถูกปฏิเสธ
T6  ใส่คูปองคนละประเภท              → ถูกปฏิเสธ
T7  ลงขายคูปองที่หมดอายุ            → ถูกปฏิเสธ
T24 invariant · ทุกใบในรายการอยู่ในมือผู้ขายจริง
```

**`listing.service.ts` ไม่เช็คเงื่อนไขพวกนี้เองเลย** — เช็คที่โค้ดก่อนแล้วค่อย `INSERT`
จะมีช่องให้สถานะเปลี่ยนระหว่างทาง ปล่อยให้ trigger ตัดสินแล้วแปลงข้อความเป็น error code

---

## คูปองใบเดียวกันอยู่ในสองรายการขายพร้อมกันไม่ได้

```sql
CREATE UNIQUE INDEX uq_reservation_exclusive
  ON reservation (subject_type, subject_id)
  WHERE released_at IS NULL
    AND subject_type IN ('COUPON_UNIT','LISTING','ESCROW');
```

index เดียวกับที่ FEAT-05 แคบลงไว้ — ที่นั่นเอา `POINT_BALANCE` ออกเพราะยอดบวกกันได้
ที่นี่ `COUPON_UNIT` ยังอยู่ในนั้น เพราะคูปองใบหนึ่งมีได้เจ้าของเดียว

```text
T9   จองคูปองใบเดียวกันในสองรายการ → ถูกปฏิเสธ
T10  จองรายการขายเดิมซ้อนกัน       → ถูกปฏิเสธ
T16  ปล่อยจองแล้วลงขายใหม่ได้
```

---

## คูปองถูกกันไว้นานกว่าชุดก่อนๆ

ใน FEAT-05 ยอดถูกปล่อยเมื่อ operation จบ · ที่นี่**ไม่ใช่**

```text
operation FINALIZED  →  listing ACTIVE  →  คูปองยังถูกกันอยู่
                                             ปล่อยเมื่อขายหมด (FEAT-10)
                                             หรือถอดออก (FEAT-09)
```

เพราะรายการที่ `ACTIVE` คือรายการที่คนอื่นกดซื้อได้ — ถ้าปล่อยคูปองตอนนั้น
ผู้ขายจะเอาใบเดิมไปลงขายที่อื่นได้ทั้งที่ยังขายอยู่ที่นี่

trigger `trg_reservation_release_timing` ยังกันไม่ให้ปล่อยก่อน operation จบ (T15)
แต่การปล่อยจริงเกิดในชุดถัดไป ไม่ใช่ชุดนี้

---

## จำนวนที่ประกาศต้องตรงกับใบที่ใส่จริง

```sql
CREATE TRIGGER trg_listing_quantity_match AFTER INSERT ON listing_item ...
  IF v_n > v_q THEN RAISE ...
```

`quantity` ถูกเซ็ตจากความยาวของ `couponCodeIds` ในชั้น service อยู่แล้ว
trigger นี้เป็นชั้นที่สอง กันกรณีที่มีใครเขียนตารางตรงๆ (T3)

---

## เริ่มยังไง

```bash
# 1 · สร้างฐานข้อมูล
createdb feat08
psql -d feat08 -v ON_ERROR_STOP=1 -f db/migration.sql

# 2 · พิสูจน์ว่า schema ให้สิ่งที่ RFD สัญญาไว้จริง
psql -d feat08 -f tests/acceptance.sql
#    ทุกแถวต้อง PASS · รันซ้ำกี่รอบก็ได้ ไม่ทิ้งข้อมูลไว้

# 3 · entity
export DATABASE_URL="postgresql://localhost/feat08"
npx prisma generate --schema db/schema.prisma
rm -rf typings/                 # ลบ stub ทิ้งหลัง generate

# 4 · type check
npx tsc -p tsconfig.json
```

---

## กฎที่ฝังอยู่ใน schema แล้ว · ไม่ต้องพึ่งโค้ด

| กฎ | บังคับด้วย |
|---|---|
| ลงขายได้เฉพาะใบที่ `HELD` และอยู่ในมือตัวเอง | trigger `trg_listing_item_valid` |
| ใบที่หมดอายุหรือคนละประเภทลงขายไม่ได้ | trigger เดียวกัน |
| ใส่ใบเกิน `quantity` ที่ประกาศไม่ได้ | trigger `trg_listing_quantity_match` |
| คูปองใบเดียวอยู่ในสองรายการขายไม่ได้ | `uq_reservation_exclusive` |
| ปล่อยจองก่อนงานจบไม่ได้ | trigger `trg_reservation_release_timing` |
| ค่าที่มาจาก chain แก้ไม่ได้หลังเขียน | trigger `trg_listing_chain_immutable` |
| ราคาต้องมากกว่า 0 | `CHECK (unit_price > 0)` |
| `chain_listing_id` ผูกกับรายการเดียว | `uq_listing_chain` |
| รายการขายอันเดียวสั่งงานซ้อนไม่ได้ | `uq_listing_inflight` |
| broadcast ไม่ได้ถ้า `raw_tx` ยังไม่ลงตาราง | `ck_rawtx_before_broadcast` |
| `nonce` ของ signer ใช้ซ้ำไม่ได้ | `uq_signer_nonce` |

---

## ผลการตรวจ

| สิ่งที่ตรวจ | ด้วยอะไร | ผล |
|---|---|---|
| `db/migration.sql` | รันบน PostgreSQL 16.13 จริง | 14 ตาราง · 32 index · 4 trigger · ผ่าน |
| `tests/acceptance.sql` | รันบนฐานข้อมูลเดียวกัน | **PASS 25 · FAIL 0** |
| `api/openapi.yaml` | `openapi-spec-validator` | valid · 3 path · 11 schema · 10 response |
| `db/schema.prisma` | เทียบกับ `information_schema` ของ DB จริง | 14/14 ตาราง ตรง · ไม่มีคอลัมน์หลุด |
| `src/*.ts` | `tsc --strict --noUncheckedIndexedAccess` | 0 error |
| `diagrams/*.mmd` | render ด้วย mermaid จริง | 3/3 ผ่าน |

---

## 25 ข้อรับประกันที่ test พิสูจน์

| # | ข้อ |
|---|---|
| T1 | ลงขายซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows |
| T2 | ขาย 5 จาก 10 ใบได้ · ระบุใบที่ขายเจาะจง |
| T3 | ใส่ใบที่ 6 ทั้งที่ประกาศ `quantity` 5 → ถูกปฏิเสธ |
| T4 | ลงขายคูปองของร้านอื่น → ถูกปฏิเสธที่ฐานข้อมูล |
| T5 | ลงขายใบที่สถานะยังไม่ `HELD` → ถูกปฏิเสธ |
| T6 | ใส่คูปองคนละประเภทกับรายการขาย → ถูกปฏิเสธ |
| T7 | ลงขายคูปองที่หมดอายุไปแล้ว → ถูกปฏิเสธ |
| T8 | ราคา 0 หรือติดลบ → ถูกปฏิเสธ |
| T9 | จองคูปองใบเดียวกันในสองรายการขาย → ถูกปฏิเสธ |
| T10 | จองรายการขายเดิมซ้อนกัน → ถูกปฏิเสธ |
| T11 | ลงขายมี 3 step เรียง `approveCoupon` → `createListing` → `lockInVault` |
| T12 | `step_index` ซ้ำในงานเดียวกัน → ถูกปฏิเสธ |
| T13 | เปลี่ยน step เป็น `SUBMITTED` โดยไม่มี `raw_tx` → ถูกปฏิเสธ |
| T14 | ใช้ `nonce` เดิมของ signer ตัวเดิมซ้ำ → ถูกปฏิเสธ |
| T15 | ปล่อยจองก่อนงานจบไม่ได้ · พอ `CHAIN_REVERTED` แล้วปล่อยได้ |
| T16 | ปล่อยจองแล้วคูปองใบเดิมลงขายใหม่ได้ |
| T17 | แก้ `chain_listing_id` ของรายการที่อยู่บน chain แล้ว → ถูกปฏิเสธ |
| T18 | contract + `chain_listing_id` ซ้ำ → ถูกปฏิเสธ |
| T19 | สั่งงานกับรายการขายเดิมซ้อนกัน → ถูกปฏิเสธ |
| T20 | เก็บราคาเป็น uint256 สูงสุดได้ครบทุกหลัก |
| T21 | `topic` ที่ไม่มีเวอร์ชันต่อท้าย → ถูกปฏิเสธ |
| T22 | ไม่มี `operation` ที่ไม่มี `outbox` คู่กัน |
| T23 | ไม่มีรายการขายที่ `ACTIVE` แต่ยังไม่อยู่บน chain |
| T24 | ทุกใบในรายการขายอยู่ในมือผู้ขายจริง |
| T25 | อ่าน log ช่วงเดิมซ้ำ → `chain_event` ไม่เกิดแถวซ้ำ |

---

## บันทึกจากการเขียน test

T7 แดงตอนรันครั้งแรก เพราะ fixture ใช้ `pg_sleep(1.1)` รอให้คูปองหมดอายุ
แต่ **`now()` ใน PostgreSQL หยุดอยู่ที่เวลาเริ่ม transaction** — `pg_sleep` ไม่ทำให้มันเดิน

แก้ที่ fixture (ตั้ง `expires_at` ไว้ในอดีตตั้งแต่แรก) ไม่ใช่แก้ trigger ให้ใช้
`clock_timestamp()` เพราะ `now()` เป็นพฤติกรรมที่ถูกต้องสำหรับการตัดสินในหนึ่ง transaction

---

## ยังไม่ได้ทำในชุดนี้

1. **worker** — มีชั้น ADMIT · การเซ็นและ broadcast ยังไม่มีโค้ด
2. **ABI ของ contract** — `approveCoupon` `createListing` `lockInVault`
   เป็นข้อกำหนดที่ contract ต้องมี ยังไม่มีของจริง
3. **การปล่อยคูปองที่กันไว้** — เกิดตอนถอด (FEAT-09) หรือขายหมด (FEAT-10)
4. **ค่าธรรมเนียม** — RFD 12 Q1 ยังไม่ตัดสิน
5. **การแก้ราคาของรายการที่ `ACTIVE`** — ยังไม่มี endpoint · ถ้าจะทำควรเป็น
   ถอดแล้วลงใหม่ ไม่ใช่แก้ในที่ เพราะราคาอยู่บน chain
6. **unit test ฝั่ง TypeScript** — มีแต่ test ระดับ schema

---

## อ้างอิง

| เอกสาร | ส่วนที่เกี่ยวข้อง |
|---|---|
| RFD 2 | Write Path · **§3.5 ตัวอย่างลงขาย 3 step** · D4 · §4-F ทางที่ร่างผิด |
| RFD 3 | Idempotency · D1 |
| RFD 12 | Marketplace · D3 การจองของชิ้นเดียว · F5 ปัญหาของ delist เดิม |
| RFD 14 | Money · ราคาเป็น base units |
| FEAT-07 | `coupon_code` ต้องอยู่สถานะ `HELD` ก่อน |
| FEAT-09 | ถอดรายการขาย · ปล่อยคูปองที่กันไว้ |
| FEAT-10 | ซื้อคูปอง · ปล่อยคูปองและย้ายเจ้าของ |
| `data-model-v1` | Group A · Group B · Group D |
