# FEAT-05 · Transfer Point · dev pack

ร้านโอน point ให้ลูกค้า · ทีละคนหรือเป็นชุดถึง 1000 คน

```text
pack05/
├── api/openapi.yaml           OpenAPI 3.1 · validate ผ่าน
├── db/migration.sql           DDL · รันบน PostgreSQL 16 จริงแล้ว
├── db/schema.prisma           entity · ตรงกับ DB ทุกคอลัมน์
├── src/types.ts               type ที่ใช้ร่วมกัน · tsc strict ผ่าน
├── src/transfer.service.ts    ชั้น ADMIT + projector
├── tests/acceptance.sql       20 ข้อรับประกัน · PASS 20 FAIL 0
└── diagrams/                  sequence · ER · state
```

---

## เรื่องใหญ่ที่สุดของ feature นี้ · ยอดบวกกันได้

ชุดก่อนๆ กันของซ้ำด้วย partial unique index

```sql
CREATE UNIQUE INDEX uq_reservation_exclusive
  ON reservation (subject_type, subject_id) WHERE released_at IS NULL;
```

ใช้กับ coupon หนึ่งใบได้ เพราะใบหนึ่งมีคนจองได้คนเดียว
แต่ใช้กับยอด point **ไม่ได้** — ร้านที่มี 1000 point ต้องโอนให้ลูกค้าหลายคนพร้อมกันได้

ถ้าคง `POINT_BALANCE` ไว้ใน index นั้น ร้านจะโอนได้ครั้งละหนึ่งรายการเท่านั้น
ชุดนี้จึง **แคบ index ลงเหลือเฉพาะชนิดที่เป็นของชิ้นเดียว** ตามที่ RFD 9 Q4 เสนอไว้

```sql
CREATE UNIQUE INDEX uq_reservation_exclusive
  ON reservation (subject_type, subject_id)
  WHERE released_at IS NULL
    AND subject_type IN ('COUPON_UNIT','LISTING','ESCROW');
```

**T4 กับ T8 คือคู่ที่พิสูจน์ว่าการแคบนี้ถูกต้อง** — T4 ยืนยันว่าจองยอด point พร้อมกันได้
T8 ยืนยันว่า coupon ยังจองซ้อนไม่ได้เหมือนเดิม ถ้าแคบเกินไป T8 จะแดง

---

## แล้วอะไรกันไม่ให้จองเกินยอด

trigger ที่ล็อกเฉพาะ subject นั้น แล้วตรวจผลรวม

```sql
PERFORM pg_advisory_xact_lock(hashtextextended(NEW.subject_id, 0));

v_avail := f_available_points(v_pt, v_kind, v_holder, now());
IF NEW.amount > v_avail THEN RAISE EXCEPTION ...
```

`pg_advisory_xact_lock` ครอบแค่ key เดียว จึงไม่กันการโอนของ point type อื่นหรือร้านอื่น
ต่างจาก `LOCK TABLE` ที่จะทำให้ทั้งระบบรอกัน

**และโค้ดฝั่ง service ไม่เช็คเองว่ายอดพอไหม** — ถ้าเช็คด้วย `SELECT` ก่อนแล้วค่อย `INSERT`
จะมีช่องให้คำขออื่นแทรกระหว่างทาง · ปล่อยให้ trigger เป็นตัวตัดสิน แล้วแปลง error เป็น `422`

```text
T3  จอง 1001 ทั้งที่ใช้ได้ 1000        → ถูกปฏิเสธ
T4  จอง 400 แล้ว 300 พร้อมกัน         → ได้ · เหลือ 300
T5  จองเพิ่ม 301 ทั้งที่เหลือ 300        → ถูกปฏิเสธ
```

---

## ยอด point ไม่มีคอลัมน์ "ยอดคงเหลือ" ที่ไหนเลย

point หมดอายุได้ และหมดอายุโดยไม่มี event บน chain (RFD 10)
ยอดจึงเก็บแยกเป็น bucket ตาม epoch ที่ได้รับ

```text
ยอดที่ใช้ได้ = Σ bucket ที่ expires_at ยังไม่ถึง − Σ reservation ที่ยังไม่ปล่อย
```

คำนวณตอน query ทุกครั้ง · ถ้าเก็บผลลัพธ์ไว้ ค่าจะผิดทันทีที่เวลาเดินผ่านวันหมดอายุ
โดยไม่มีอะไรมากระตุ้นให้อัปเดต

**T20 บังคับข้อนี้ที่โครงสร้าง** — ตรวจว่าตาราง `point_balance_bucket`
ไม่มีคอลัมน์ชื่อไหนที่สื่อถึงยอดสำเร็จรูป (`available` `balance` `total` `remaining`)
ใครเผลอเพิ่มเข้ามา test แดงทันที

`expires_at` เป็นฟังก์ชันบริสุทธิ์ของ (เวลาที่ได้รับ, ค่าคงที่ของ contract)
จึง rebuild projection กี่ครั้งก็ได้ค่าเดิม

---

## ปล่อยยอดที่จองไว้เมื่อไหร่

| operation status | ยอดที่จองไว้ |
|---|---|
| `PENDING` `SUBMITTED` `CONFIRMED` | ยังถูกกันอยู่ |
| `FINALIZED` | ปล่อย · ยอดถูกหักจริงแล้ว |
| `CHAIN_REVERTED` | ปล่อย · ยอดกลับมาใช้ได้ |
| `MANUAL_REVIEW` | **ยังถูกกันอยู่** · ต้องให้คนตัดสินก่อน |

ข้อนี้เดิมเป็นแค่ข้อตกลงใน RFD 9 · ชุดนี้ทำให้เป็นกฎที่ฐานข้อมูลบังคับ

```sql
CREATE TRIGGER trg_reservation_release_timing
  BEFORE UPDATE ON reservation
  FOR EACH ROW EXECUTE FUNCTION f_check_release_timing();
```

> trigger ตัวนี้เกิดจากการที่ **T18 แดงตอนรันครั้งแรก** — fixture ของ test เอง
> ปล่อยยอดตอน operation ยัง `PENDING` ซึ่งไม่มีอะไรห้ามไว้
> แทนที่จะแก้ test ให้ผ่าน จึงเติมกฎที่หายไปลงใน schema

---

## โอนเป็นชุด · หนึ่ง operation หลาย step

```text
ผู้รับ 243 คน
  → operation 1 อัน      ← ผู้เรียกติดตามด้วย operationId เดียว
  → operation_step 3 อัน  ← 100 + 100 + 43
  → chain tx 3 ใบ
```

`recipient_count` จำกัดที่ 100 ต่อ step เพราะเกินกว่านั้น gas ต่อ tx เกิน block limit
บังคับด้วย `CHECK (recipient_count BETWEEN 1 AND 100)` ไม่ใช่แค่ค่าคงที่ในโค้ด

ถ้าบาง step สำเร็จแต่บาง step ล้ม → `MANUAL_REVIEW` · ยอดที่จองไว้ยังถูกกัน

---

## การหักยอดแบบ FIFO

ผู้ส่งถูกหักจาก bucket ที่ใกล้หมดอายุที่สุดก่อน (`ORDER BY expires_at`)

**ลำดับนี้ต้องตรงกับที่ contract ทำ** ไม่งั้นยอดในระบบกับบน chain จะเพี้ยนแบบสืบย้อนยาก
ยังไม่ได้ยืนยันกับ contract จริง — บันทึกไว้ที่ RFD 10 Q1

---

## เริ่มยังไง

```bash
# 1 · สร้างฐานข้อมูล
createdb feat05
psql -d feat05 -v ON_ERROR_STOP=1 -f db/migration.sql

# 2 · พิสูจน์ว่า schema ให้สิ่งที่ RFD สัญญาไว้จริง
psql -d feat05 -f tests/acceptance.sql
#    ทุกแถวต้อง PASS · รันซ้ำกี่รอบก็ได้ ไม่ทิ้งข้อมูลไว้

# 3 · entity
export DATABASE_URL="postgresql://localhost/feat05"
npx prisma generate --schema db/schema.prisma
rm -rf typings/                 # ลบ stub ทิ้งหลัง generate

# 4 · type check
npx tsc -p tsconfig.json
```

---

## กฎที่ฝังอยู่ใน schema แล้ว · ไม่ต้องพึ่งโค้ด

| กฎ | บังคับด้วย |
|---|---|
| จองเกินยอดที่ใช้ได้ไม่ได้ | trigger `trg_point_reservation_balance` + advisory lock |
| ปล่อยยอดก่อนงานจบไม่ได้ | trigger `trg_reservation_release_timing` |
| ยอด point จองพร้อมกันหลายรายการได้ | `uq_reservation_exclusive` ไม่ครอบ `POINT_BALANCE` |
| ของชิ้นเดียวยังจองซ้อนไม่ได้ | `uq_reservation_exclusive` ครอบ `COUPON_UNIT` `LISTING` `ESCROW` |
| bucket หมดอายุก่อนได้รับไม่ได้ | `CHECK (expires_at > received_at)` |
| หนึ่ง bucket ต่อ (ผู้ถือ, point type, epoch) | `uq_bucket` |
| step ละไม่เกิน 100 ผู้รับ | `CHECK (recipient_count BETWEEN 1 AND 100)` |
| ไม่มีคอลัมน์ยอดคงเหลือสำเร็จรูป | ตรวจโครงสร้างด้วย T20 |
| broadcast ไม่ได้ถ้า `raw_tx` ยังไม่ลงตาราง | `ck_rawtx_before_broadcast` |
| `nonce` ของ signer ใช้ซ้ำไม่ได้ | `uq_signer_nonce` |

---

## ผลการตรวจ

| สิ่งที่ตรวจ | ด้วยอะไร | ผล |
|---|---|---|
| `db/migration.sql` | รันบน PostgreSQL 16.13 จริง | 15 ตาราง · 32 index · 2 trigger · ผ่าน |
| `tests/acceptance.sql` | รันบนฐานข้อมูลเดียวกัน | **PASS 20 · FAIL 0** |
| `api/openapi.yaml` | `openapi-spec-validator` | valid · 3 path · 11 schema · 9 response |
| `db/schema.prisma` | เทียบกับ `information_schema` ของ DB จริง | 15/15 ตาราง ตรง · ไม่มีคอลัมน์หลุด |
| `src/*.ts` | `tsc --strict --noUncheckedIndexedAccess` | 0 error |
| `diagrams/*.mmd` | render ด้วย mermaid จริง | 3/3 ผ่าน |

---

## 20 ข้อรับประกันที่ test พิสูจน์

| # | ข้อ |
|---|---|
| T1 | โอน point ซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows |
| T2 | bucket ที่หมดอายุไม่นับในยอดที่ใช้ได้ (รวม 1500 · ใช้ได้ 1000) |
| T3 | จอง 1001 ทั้งที่ใช้ได้ 1000 → ถูกปฏิเสธ |
| T4 | ร้านโอนให้หลายคนพร้อมกันได้ · จอง 400+300 เหลือ 300 |
| T5 | จองเพิ่ม 301 ทั้งที่เหลือ 300 → ถูกปฏิเสธ |
| T6 | ปล่อยจองก่อนงานจบไม่ได้ · พอ `CHAIN_REVERTED` แล้วคืน 400 → เหลือ 700 |
| T7 | `subject_id` ที่ไม่ใช่รูปแบบ `pt\|kind\|holder` → ถูกปฏิเสธ |
| T8 | จอง coupon ใบเดียวกันซ้อน → ยังถูกปฏิเสธเหมือนเดิม |
| T9 | bucket ที่ `expires_at` อยู่ก่อน `received_at` → ถูกปฏิเสธ |
| T10 | สร้าง bucket ซ้ำใน epoch เดิมของผู้ถือเดิม → ถูกปฏิเสธ |
| T11 | ยอดติดลบหรือศูนย์เข้าไม่ได้ |
| T12 | เก็บ uint256 สูงสุด (2^256−1) ได้ครบทุกหลัก |
| T13 | โอน 243 คน = 3 step · step ที่เกิน 100 คน → ถูกปฏิเสธ |
| T14 | เปลี่ยน step เป็น `SUBMITTED` โดยไม่มี `raw_tx` → ถูกปฏิเสธ |
| T15 | ใช้ `nonce` เดิมของ signer ตัวเดิมซ้ำ → ถูกปฏิเสธ |
| T16 | ทุก operation มียอด `DEBIT` เท่ากับ `CREDIT` (บัญชีคู่สมดุล) |
| T17 | query เลือก bucket ที่ใกล้หมดอายุที่สุดก่อน |
| T18 | ไม่มีการปล่อยจองของงานที่ยังไม่จบ (บังคับด้วย trigger) |
| T19 | ไม่มี `operation` ที่ไม่มี `outbox` คู่กัน |
| T20 | bucket ไม่มีคอลัมน์ยอดคงเหลือสำเร็จรูป · คิดตอน query เท่านั้น |

---

## ยังไม่ได้ทำในชุดนี้

1. **worker** — มีชั้น ADMIT และ projector · การเซ็นและ broadcast ยังไม่มีโค้ด
2. **ลำดับ FIFO ต้องยืนยันกับ contract** — ถ้า contract หัก bucket คนละลำดับ
   ยอดในระบบกับบน chain จะเพี้ยน (RFD 10 Q1)
3. **ลูกค้าโอนต่อให้กันเอง** — RFD 9 ตัดสินว่า v1 ยังไม่ให้ และต้องบังคับที่ contract
   ไม่ใช่ที่ API · ชุดนี้ยังไม่มีการบังคับนั้น
4. **การแจ้งเตือนก่อน point หมดอายุ** — เป็น query บน `expires_at` ตรงๆ ยังไม่มี endpoint
5. **unit test ฝั่ง TypeScript** — มีแต่ test ระดับ schema

---

## อ้างอิง

| เอกสาร | ส่วนที่เกี่ยวข้อง |
|---|---|
| RFD 2 | Write Path · R1 R2 D1 D4 D9 |
| RFD 3 | Idempotency · D1 |
| RFD 9 | Point Issuance & Transfer · การจอง · batch · **Q4 การแคบ index** |
| RFD 10 | Expirable Points · bucket · FIFO · Q1 |
| RFD 14 | Money · base units · string บน wire |
| FEAT-04 | `point_type` ต้อง `LIVE` ก่อน · `point_type_chain` ให้ค่า epoch |
| `data-model-v1` | Group A · Group B · Group D |
