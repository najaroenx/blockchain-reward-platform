# FEAT-04 · Create Point Type · dev pack

ร้านประกาศ point ของตัวเอง แล้วระบบ deploy token ผ่าน factory บน chain

```text
pack04/
├── api/openapi.yaml             OpenAPI 3.1 · validate ผ่าน
├── db/migration.sql             DDL · รันบน PostgreSQL 16 จริงแล้ว
├── db/schema.prisma             entity · ตรงกับ DB ทุกคอลัมน์
├── src/types.ts                 type ที่ใช้ร่วมกัน · tsc strict ผ่าน
├── src/point-type.service.ts    ชั้น ADMIT + projector
├── tests/acceptance.sql         17 ข้อรับประกัน · PASS 17 FAIL 0
└── diagrams/                    sequence · ER · state
```

---

## การตัดสินใจหลัก · แยกเป็นสองตาราง

| ตาราง | ค่ามาจากไหน | เขียนโดย | ลบทิ้งแล้ว replay ได้ไหม |
|---|---|---|---|
| `point_type` | ร้านเป็นคนพิมพ์ | api ตอน ADMIT | **ไม่ได้** |
| `point_type_chain` | chain | projector | ได้เสมอ |

ถ้ารวมเป็นตารางเดียว ตารางนั้นจะ rebuild ไม่ได้ เพราะชื่อ `"แต้มสะสมสุขใจ"` ไม่ได้อยู่บน chain
ซึ่งผิดกฎของ Group D ที่ว่า *ลบทิ้งทั้งตาราง แล้ว replay `chain_event` ใหม่ ต้องได้ค่าเดิมเป๊ะ* (RFD 6 §3.2)

แยกแล้วแต่ละตารางมีเจ้าของคนเดียวและกฎการกู้คืนที่ชัดเจน

```text
rebuild projection:
  TRUNCATE point_type_chain          ← ทำได้
  TRUNCATE point_type                ← ห้ามทำ · ชื่อหาย
  replay chain_event
  → point_type_chain กลับมาครบ
```

**T17 บังคับข้อนี้ที่ระดับโครงสร้าง** — ตรวจว่า `point_type_chain` ไม่มีคอลัมน์ `name`
`symbol` `decimals` `status` หรือ `merchant_id` เลย ถ้าวันหนึ่งมีคนย้ายคอลัมน์มาใส่ test แดงทันที

---

## ทำไมคืน `202` ไม่ใช่ `201`

ต่างจาก FEAT-01 ที่คืน `201` ได้ เพราะร้านมีตัวตนและล็อกอินได้โดยไม่ต้องรอ chain

point type ที่ยังไม่มี contract คือ point type ที่ **ใช้ไม่ได้** ไม่มีอะไรจะส่งคืนก่อน
จึงคืน `202` พร้อม `operationId` และ `status: REQUESTED`

แต่ **ชื่อและ symbol ถูกจองทันทีที่ ADMIT** ไม่ต้องรอ chain — ร้านจะได้ไม่เสียชื่อ
ให้คนอื่นระหว่างรอ และถ้า deploy ล้ม ชื่อถูกปล่อยคืนโดยอัตโนมัติ

```sql
CREATE UNIQUE INDEX uq_point_symbol
  ON point_type (merchant_id, symbol) WHERE status <> 'FAILED';
```

`WHERE status <> 'FAILED'` คือสิ่งที่ทำให้การปล่อยคืนเกิดขึ้นเอง
ไม่ต้องมี job ไปลบแถว และประวัติว่าเคยพยายามสร้างแล้วล้มยังอยู่ครบ

---

## ไม่ `SELECT` มาเช็คชื่อซ้ำก่อน

```ts
// ไม่ทำแบบนี้
const exists = await tx.pointType.findFirst({ where: { merchantId, symbol } })
if (exists) throw new Conflict('SYMBOL_TAKEN')
await tx.pointType.create({ ... })        // ← ช่องว่างตรงนี้
```

ระหว่าง `findFirst` กับ `create` มีช่องให้ request อื่นแทรกเข้ามาได้เสมอ
ชุดนี้ปล่อยให้ unique index เป็นตัวตัดสิน แล้วแปลง error เป็น `409`
โดยดูชื่อ constraint ว่าชนที่ `uq_point_symbol` หรือ `uq_point_name`

เป็นรูปแบบเดียวกับที่ใช้กับ `idempotency_key` ใน RFD 3 — **ให้ฐานข้อมูลตัดสิน
ไม่ใช่โค้ดเช็คแล้วหวังว่าไม่มีใครแทรก**

---

## ร้านต้อง `ACTIVE` ก่อน · บังคับด้วย trigger

```sql
CREATE TRIGGER trg_point_type_merchant_active
  BEFORE INSERT ON point_type
  FOR EACH ROW EXECUTE FUNCTION f_merchant_must_be_active();
```

`CHECK` อ้างตารางอื่นไม่ได้ จึงใช้ trigger แทน
ผลคือร้านที่ยังอยู่ `PENDING` จาก FEAT-01 สร้าง point type ไม่ได้
ไม่ว่าจะเรียกผ่าน API, ผ่าน script, หรือ `INSERT` ตรงใน psql

---

## ค่า epoch กับการหมดอายุ (RFD 10)

`point_type_chain` เก็บสามค่าที่อ่านจาก contract ตอน deploy

```text
genesis_at       จุดเริ่มนับ epoch
epoch_seconds    ความยาวหนึ่ง epoch
validity_epochs  point ที่ได้รับใช้ได้กี่ epoch
```

วันหมดอายุของ point ก้อนหนึ่งคำนวณจากสามค่านี้ **ไม่ใช่จากเวลาที่รัน**

```ts
expiryOf(p, receivedAt) = genesis_at + (epochOf(receivedAt) + validity_epochs) × epoch_seconds
```

นี่คือเหตุผลที่ ERC-7818 ซึ่งหมดอายุโดยไม่มี event บน chain ยังไม่ทำลายกฎ replay
`expires_at` เป็นฟังก์ชันบริสุทธิ์ของ (event, ค่าคงที่) — rebuild กี่ครั้งก็ได้ค่าเดิม

**trigger `trg_point_chain_immutable` กันไม่ให้แก้สามค่านี้หลังถูกเขียน**
ถ้าแก้ได้ ยอดที่คำนวณไว้แล้วทั้งหมดจะเปลี่ยนความหมายย้อนหลัง

---

## เริ่มยังไง

```bash
# 1 · สร้างฐานข้อมูล
createdb feat04
psql -d feat04 -v ON_ERROR_STOP=1 -f db/migration.sql

# 2 · พิสูจน์ว่า schema ให้สิ่งที่ RFD สัญญาไว้จริง
psql -d feat04 -f tests/acceptance.sql
#    ทุกแถวต้อง PASS · รันซ้ำกี่รอบก็ได้ ไม่ทิ้งข้อมูลไว้

# 3 · entity
export DATABASE_URL="postgresql://localhost/feat04"
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
| ร้านที่ยังไม่ `ACTIVE` สร้าง point type ไม่ได้ | trigger `trg_point_type_merchant_active` |
| ค่าที่มาจาก chain แก้ไม่ได้หลังเขียน | trigger `trg_point_chain_immutable` |
| symbol ต้องเป็นตัวใหญ่ล้วน 2–11 ตัว | `CHECK (symbol ~ '^[A-Z][A-Z0-9]{1,10}$')` |
| `decimals` อยู่ในช่วง 0–30 | `CHECK (decimals BETWEEN 0 AND 30)` |
| ชื่อและ symbol ซ้ำในร้านเดียวไม่ได้ | `uq_point_symbol` · `uq_point_name` |
| deploy ล้มแล้วชื่อถูกปล่อยคืน | `WHERE status <> 'FAILED'` ใน partial index |
| contract address ผูกกับ point type เดียว | `uq_point_chain_address` |
| point type อันเดียวสั่ง deploy ซ้อนไม่ได้ | `uq_point_deploy_inflight` |
| ค่า epoch ต้องเป็นบวก | `CHECK (epoch_seconds > 0)` |

---

## ผลการตรวจ

| สิ่งที่ตรวจ | ด้วยอะไร | ผล |
|---|---|---|
| `db/migration.sql` | รันบน PostgreSQL 16.13 จริง | 12 ตาราง · 26 index · 2 trigger · ผ่าน |
| `tests/acceptance.sql` | รันบนฐานข้อมูลเดียวกัน | **PASS 17 · FAIL 0** |
| `api/openapi.yaml` | `openapi-spec-validator` | valid · 3 path · 10 schema · 10 response |
| `db/schema.prisma` | เทียบกับ `information_schema` ของ DB จริง | 12/12 ตาราง ตรง · ไม่มีคอลัมน์หลุด |
| `src/*.ts` | `tsc --strict --noUncheckedIndexedAccess` | 0 error |
| `diagrams/*.mmd` | render ด้วย mermaid จริง | 3/3 ผ่าน |

---

## 17 ข้อรับประกันที่ test พิสูจน์

| # | ข้อ |
|---|---|
| T1 | สร้าง point type ซ้ำด้วย key เดิม → แถวที่สองได้ 0 rows |
| T2 | ร้านที่ `status` ยังไม่ `ACTIVE` สร้าง point type ไม่ได้ |
| T3 | symbol ที่เป็นตัวเล็ก สั้นไป หรือมีช่องว่าง → ถูกปฏิเสธ |
| T4 | `decimals` เกิน 30 หรือติดลบ → ถูกปฏิเสธ |
| T5 | ร้านเดียวกันใช้ symbol ซ้ำ → ถูกปฏิเสธ |
| T6 | ชื่อเดียวกันที่มีช่องว่างหน้าหลัง → ถูกปฏิเสธ |
| T7 | deploy ล้มแล้วใช้ชื่อและ symbol เดิมสร้างใหม่ได้ |
| T8 | สั่ง deploy point type เดิมซ้อนกัน → ถูกปฏิเสธ |
| T9 | แก้ `contract_address` ของ point type ที่ deploy แล้ว → ถูกปฏิเสธ |
| T10 | contract address เดียวกันผูกกับสอง point type → ถูกปฏิเสธ |
| T11 | `epoch_seconds` หรือ `validity_epochs` เป็น 0 → ถูกปฏิเสธ |
| T12 | เปลี่ยน step เป็น `SUBMITTED` โดยไม่มี `raw_tx` → ถูกปฏิเสธ |
| T13 | `topic` ที่ไม่มีเวอร์ชันต่อท้าย → ถูกปฏิเสธ |
| T14 | อ่าน log ช่วงเดิมซ้ำ → `chain_event` ไม่เกิดแถวซ้ำ |
| T15 | ไม่มี point type ที่ `LIVE` แต่ยังไม่มี contract |
| T16 | ไม่มี `operation` ที่ไม่มี `outbox` คู่กัน |
| T17 | `point_type_chain` ไม่มีคอลัมน์ที่มาจากร้าน · replay ได้ทั้งตาราง |

---

## ยังไม่ได้ทำในชุดนี้

1. **worker** — ชุดนี้มีชั้น ADMIT และโครง projector · การเซ็นและ broadcast ยังไม่มีโค้ด
2. **ABI ของ factory** — `createPointToken(name, symbol, decimals)` เป็นข้อกำหนดที่ contract ต้องมี
   ยังไม่มีของจริง และยังไม่ยืนยันว่า event ปล่อย `genesis_at` `epoch_seconds` ออกมาด้วยหรือไม่
   ถ้าไม่ปล่อย ต้องอ่านด้วย `eth_call` ซึ่งทำให้ projector ไม่ pure (RFD 10 Q2)
3. **`RETIRED`** — enum มีแล้ว แต่ยังไม่มี endpoint
4. **การออก point** — อยู่ใน FEAT-05
5. **unit test ฝั่ง TypeScript** — มีแต่ test ระดับ schema

---

## อ้างอิง

| เอกสาร | ส่วนที่เกี่ยวข้อง |
|---|---|
| RFD 2 | Write Path · R1 R2 D1 D4 D9 |
| RFD 3 | Idempotency · D1 · scope `merchant:<id>` |
| RFD 6 | Projections · §3.2 กฎ replay · การแยกตาราง |
| RFD 9 | Point Issuance · การสร้าง point type |
| RFD 10 | Expirable Points · `genesis_at` `epoch_seconds` `validity_epochs` |
| RFD 14 | Money · `decimals` ใช้ที่ชั้นแสดงผลเท่านั้น |
| FEAT-01 | `merchant` ต้อง `ACTIVE` ก่อน |
| `data-model-v1` | Group A · Group B · Group D |
