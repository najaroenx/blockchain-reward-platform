# FEAT-06 · Point Balance · dev pack

อ่านยอด point · พยากรณ์การหมดอายุ · แจ้งเตือนล่วงหน้า

```text
pack06/
├── api/openapi.yaml          OpenAPI 3.1 · validate ผ่าน
├── db/migration.sql          DDL + 7 ฟังก์ชันอ่าน · รันบน PostgreSQL 16 จริงแล้ว
├── db/schema.prisma          entity · ตรงกับ DB ทุกคอลัมน์
├── src/types.ts              type ที่ใช้ร่วมกัน · tsc strict ผ่าน
├── src/balance.service.ts    ชั้นอ่าน + job หาคนที่ต้องแจ้งเตือน
├── tests/acceptance.sql      20 ข้อรับประกัน · PASS 20 FAIL 0
└── diagrams/                 sequence · ER · state
```

**ชุดนี้เป็นฝั่งอ่านล้วน** — ไม่มี `operation` ไม่มี `outbox` ไม่มี chain tx
จึงไม่ต้องใช้ `Idempotency-Key` เลย ยกเว้น endpoint บันทึกการแจ้งเตือนที่กันซ้ำด้วย unique index แทน

---

## หลักเดียวที่ทั้งชุดตั้งอยู่บน · ทุก query รับ `as_of`

```sql
CREATE FUNCTION f_available_points(..., p_as_of timestamptz) RETURNS numeric
LANGUAGE sql STABLE AS $$ ... WHERE expires_at > p_as_of ... $$;
```

ฟังก์ชันอ่านทุกตัว **ไม่เรียก `now()` ข้างใน** · คำตอบจึงเป็นฟังก์ชันบริสุทธิ์ของ (ข้อมูล, เวลา)

ได้สามอย่างมาฟรี

| | |
|---|---|
| ทดสอบซ้ำได้ | fixture ใช้เวลาตายตัว `T0()` ผลลัพธ์ไม่ขึ้นกับว่ารัน test ตอนไหน |
| ถามอดีตได้ | "ยอดเมื่อสิ้นเดือนที่แล้วเท่าไหร่" คือ query เดิม ส่ง `as_of` คนละค่า |
| ถามอนาคตได้ | "อีก 30 วันจะเหลือเท่าไหร่" ก็ query เดิม |

**T19 บังคับข้อนี้ที่ระดับ catalog** — อ่าน `pg_get_functiondef` ของทุกฟังก์ชันอ่าน
แล้วยืนยันว่าไม่มีตัวไหนเรียก `now()` และทุกตัวประกาศเป็น `STABLE` ไม่ใช่ `VOLATILE`
ใครเผลอเติม `now()` เข้าไป test แดงทันที

```text
T1  ถาม ณ วันนี้           → 600
T2  ถาม ณ 30 วันก่อน      → 1100   (ก้อน 500 ยังไม่หมดอายุตอนนั้น)
T3  ถามล่วงหน้า 10 วัน     → 500
T3  ถามล่วงหน้า 30 วัน     → 300
```

ไม่มี job ไหนไปลดยอด · **เวลาเดินเอง คำตอบเปลี่ยนเอง**

---

## ไม่มีคอลัมน์ `available` ที่ไหนในฐานข้อมูล

ถ้าเก็บยอดคงเหลือไว้เป็นตัวเลข ค่าจะผิดทันทีที่เวลาเดินผ่านวันหมดอายุ
โดยไม่มี event อะไรมากระตุ้นให้อัปเดต — นี่คือสมบัติของ ERC-7818 ที่ RFD 10 ชี้ไว้

**T18 ตรวจทั้งฐานข้อมูล** ว่าไม่มีคอลัมน์ชื่อ `available` `cached_balance`
`current_balance` หรือ `remaining_balance` อยู่ที่ไหนเลย

---

## index ที่ query ใช้จริง · พิสูจน์ด้วย EXPLAIN

```sql
CREATE INDEX ix_bucket_live
  ON point_balance_bucket (point_type_id, holder_kind, holder_id, expires_at)
  INCLUDE (amount)
  WHERE amount > 0;
```

ลำดับคอลัมน์ตามรูปของ query — สามตัวแรกเป็น equality ตัวสุดท้ายเป็น range
`INCLUDE (amount)` ทำให้เป็น index-only scan ไม่ต้องแตะ heap เลย
`WHERE amount > 0` ทำให้ขนาด index เท่ากับจำนวน bucket ที่ยังมียอด ไม่ใช่ทั้งประวัติ

**T20 ใส่ข้อมูล 5000 แถว รัน `ANALYZE` แล้วอ่าน plan จริงจาก `EXPLAIN`**
ยืนยันว่า planner เลือก `ix_bucket_live` จริง ไม่ใช่สแกนทั้งตาราง

```sql
FOR line IN EXECUTE format('EXPLAIN (COSTS OFF) SELECT ...') LOOP
  INSERT INTO _plan VALUES (line);
END LOOP;
SELECT bool_or(line ILIKE '%ix_bucket_live%') INTO uses_index FROM _plan;
```

เป็น test เดียวในชุดทั้งหมดที่ตรวจ **performance** ไม่ใช่ correctness
ถ้าวันหนึ่งมีคนลบ index หรือเปลี่ยนลำดับคอลัมน์ test จะแดงก่อนที่ production จะช้า

---

## ทำไมไม่ใช้ materialized view

เป็นทางเลือกแรกที่คนมักนึกถึง แต่มันย้อนกลับไปสร้างปัญหาเดิม

| | matview | query สด |
|---|---|---|
| ความเร็ว | เร็วกว่า | เร็วพอด้วย index-only scan |
| ความถูกต้อง | **ผิดระหว่างรอบ refresh** | ถูกเสมอ |
| ถามอดีต/อนาคตได้ไหม | ไม่ได้ | ได้ |

matview ต้อง refresh เป็นรอบ · ระหว่างรอบ ยอดที่เพิ่งหมดอายุจะยังนับอยู่
ซึ่งคือปัญหาเดียวกับการเก็บคอลัมน์ `available` แค่ย้ายที่

ถ้าวันหนึ่งข้อมูลโตจนช้าจริง ทางที่ควรไปก่อนคือ partition ตาม `expires_at`
ไม่ใช่ cache ค่าที่ขึ้นกับเวลา

---

## ความทันของข้อมูล · ทุก response มี `freshness`

projection ตามหลัง chain เสมอ · ถ้าไม่บอก ผู้เรียกจะเข้าใจผิดว่ายอดที่เห็นคือยอดล่าสุด

```json
"freshness": { "asOfBlock": 1002, "lagBlocks": 3, "lagSeconds": 36 }
```

`projection_watermark` มีได้แถวเดียว (PK เป็น `boolean` + `CHECK (id)`)
และ **ถอยหลังไม่ได้** — trigger `trg_watermark_monotonic` กันไว้
เพราะ projection ที่ย้อนกลับแปลว่ามีการ replay ที่ไม่ควรมองเห็นจากฝั่งอ่าน

---

## การแจ้งเตือนก่อนหมดอายุ · ไม่มี cron ที่ไล่ลดยอด

มีแค่ query หา bucket ที่ใกล้หมดอายุและยังไม่เคยแจ้งที่ระดับนั้น

```sql
LEFT JOIN expiry_notice n ON n.bucket_id = b.id AND n.threshold_days = $2
WHERE ... AND n.id IS NULL
```

```sql
CREATE UNIQUE INDEX uq_notice ON expiry_notice (bucket_id, threshold_days);
```

job ที่รันซ้ำจึงไม่ทำให้ลูกค้าได้ข้อความเดิมสองรอบ · ถ้าได้ `409` แปลว่า job อีกตัว
ทำไปแล้ว ไม่ใช่ error ที่ต้องแก้ (`isBenignConflict()` ใน `types.ts`)

ระดับที่อนุญาตมีแค่ 30, 7, 1 วัน บังคับด้วย `CHECK (threshold_days IN (30,7,1))`
ไม่ใช่ค่าคงที่ในโค้ด · และ `trg_notice_not_expired` กันไม่ให้แจ้ง "ล่วงหน้า"
ของก้อนที่หมดอายุไปแล้ว

---

## ยอดที่ใช้ได้ติดลบไม่ได้

```sql
SELECT greatest(unexpired - reserved, 0)
```

เกิดขึ้นได้จริงเมื่อ bucket หมดอายุระหว่างที่ยังมี reservation ค้างอยู่
(จองไว้ 250 แล้ว bucket ที่เหลือหมดอายุ) · **T5** ทดสอบเคสนี้ตรงๆ

---

## เริ่มยังไง

```bash
# 1 · สร้างฐานข้อมูล
createdb feat06
psql -d feat06 -v ON_ERROR_STOP=1 -f db/migration.sql

# 2 · พิสูจน์ว่า schema ให้สิ่งที่ RFD สัญญาไว้จริง
psql -d feat06 -f tests/acceptance.sql
#    ทุกแถวต้อง PASS · รันซ้ำกี่รอบก็ได้ ไม่ทิ้งข้อมูลไว้
#    T20 ใส่ข้อมูล 5000 แถวชั่วคราวเพื่ออ่าน EXPLAIN จริง แล้ว ROLLBACK ทิ้ง

# 3 · entity
export DATABASE_URL="postgresql://localhost/feat06"
npx prisma generate --schema db/schema.prisma
rm -rf typings/                 # ลบ stub ทิ้งหลัง generate

# 4 · type check
npx tsc -p tsconfig.json
```

---

## กฎที่ฝังอยู่ใน schema แล้ว · ไม่ต้องพึ่งโค้ด

| กฎ | บังคับด้วย |
|---|---|
| ฟังก์ชันอ่านไม่เรียก `now()` และเป็น `STABLE` | ตรวจ `pg_get_functiondef` ด้วย T19 |
| query ยอดต้องใช้ index | ตรวจ `EXPLAIN` ด้วย T20 |
| ไม่มีคอลัมน์ยอดคงเหลือสำเร็จรูป | ตรวจ `information_schema` ด้วย T18 |
| แจ้งเตือนซ้ำระดับเดิมไม่ได้ | `uq_notice (bucket_id, threshold_days)` |
| ระดับการแจ้งเตือนนอกนโยบายเข้าไม่ได้ | `CHECK (threshold_days IN (30,7,1))` |
| แจ้งล่วงหน้าของก้อนที่หมดอายุแล้วไม่ได้ | trigger `trg_notice_not_expired` |
| watermark ถอยหลังไม่ได้ | trigger `trg_watermark_monotonic` |
| watermark มีได้แถวเดียว | PK `boolean` + `CHECK (id)` |
| bucket หมดอายุก่อนได้รับไม่ได้ | `CHECK (expires_at > received_at)` |
| ยอดที่ใช้ได้ติดลบไม่ได้ | `greatest(..., 0)` ใน `f_available_points` |

---

## ผลการตรวจ

| สิ่งที่ตรวจ | ด้วยอะไร | ผล |
|---|---|---|
| `db/migration.sql` | รันบน PostgreSQL 16.13 จริง | 9 ตาราง · 14 index · 2 trigger · 7 ฟังก์ชัน |
| `tests/acceptance.sql` | รันบนฐานข้อมูลเดียวกัน | **PASS 20 · FAIL 0** |
| `api/openapi.yaml` | `openapi-spec-validator` | valid · 3 path · 9 schema · 8 response |
| `db/schema.prisma` | เทียบกับ `information_schema` ของ DB จริง | 9/9 ตาราง ตรง · ไม่มีคอลัมน์หลุด |
| `src/*.ts` | `tsc --strict --noUncheckedIndexedAccess` | 0 error |
| `diagrams/*.mmd` | render ด้วย mermaid จริง | 3/3 ผ่าน |

---

## 20 ข้อรับประกันที่ test พิสูจน์

| # | ข้อ |
|---|---|
| T1 | ยอดที่ใช้ได้ = 600 · ไม่นับก้อนที่หมดอายุและก้อนศูนย์ |
| T2 | ถาม ณ 30 วันก่อน → 1100 เพราะก้อน 500 ยังไม่หมดอายุ |
| T3 | ถามล่วงหน้า 10 วัน → 500 · ล่วงหน้า 30 วัน → 300 |
| T4 | จองไว้ 250 → ยอดที่ใช้ได้เหลือ 350 |
| T5 | ยอดที่ใช้ได้ไม่ติดลบ · ล่วงหน้า 30 วันได้ 50 |
| T6 | ปล่อยจอง 250 → ยอดกลับเป็น 600 |
| T7 | พยากรณ์ 30 วันข้างหน้า → 2 วัน รวม 300 |
| T8 | พยากรณ์ 365 วัน → 600 · ไม่นับก้อนหมดอายุและก้อนศูนย์ |
| T9 | หมดอายุสะสม ณ วันนี้ 500 · อีก 30 วัน 800 |
| T10 | แจ้งเตือน bucket เดิมที่ระดับ 7 วันซ้ำ → ถูกปฏิเสธ |
| T11 | แจ้ง bucket เดิมที่ระดับ 7 และ 1 วันได้ · ได้ 2 ใบ |
| T12 | `threshold_days` ที่ไม่ใช่ 30/7/1 → ถูกปฏิเสธ |
| T13 | แจ้งเตือนล่วงหน้าของ bucket ที่หมดอายุแล้ว → ถูกปฏิเสธ |
| T14 | เลื่อน watermark ถอยหลัง → ถูกปฏิเสธ |
| T15 | เพิ่มแถวที่สองใน `projection_watermark` → ถูกปฏิเสธ |
| T16 | คำนวณระยะที่ projection ตามหลัง indexer ได้ |
| T17 | เก็บ uint256 สูงสุด (2^256−1) ได้ครบทุกหลัก |
| T18 | ไม่มีคอลัมน์ยอดคงเหลือสำเร็จรูปในฐานข้อมูลเลย |
| T19 | ฟังก์ชันอ่านไม่เรียก `now()` ข้างใน และประกาศเป็น `STABLE` |
| T20 | `EXPLAIN` ยืนยันว่า query ยอดใช้ index `ix_bucket_live` จริง |

---

## ยังไม่ได้ทำในชุดนี้

1. **pagination ของรายการ bucket** — ตอนนี้คืนทั้งหมด · ผู้ถือที่มี bucket หลักพัน
   จะได้ payload ใหญ่ · ควรทำ keyset pagination บน `(expires_at, id)` ซึ่ง index รองรับอยู่แล้ว
2. **การส่งข้อความจริง** — ชุดนี้มีแค่ query หาคนที่ต้องแจ้ง และตารางกันแจ้งซ้ำ
3. **ยอดรวมข้าม point type** — ตอนนี้ถามได้ทีละ type
4. **การ partition `point_balance_bucket`** — ยังไม่จำเป็นที่ขนาดปัจจุบัน
   แต่เป็นทางที่ควรไปก่อน cache ถ้าวันหนึ่งช้า
5. **unit test ฝั่ง TypeScript** — มีแต่ test ระดับ schema

---

## อ้างอิง

| เอกสาร | ส่วนที่เกี่ยวข้อง |
|---|---|
| RFD 6 | Projections · กฎ replay · ความหน่วงของ projection |
| RFD 10 | Expirable Points · bucket · ยอดคิดตอน query · Q1 ลำดับ FIFO |
| RFD 14 | Money · base units · string บน wire · `decimals` ที่ชั้นแสดงผล |
| FEAT-04 | `point_type_chain` ให้ค่า `genesisAt` `epochSeconds` |
| FEAT-05 | สร้างและปล่อย `reservation` · ใช้ `f_available_points` ตัวเดียวกัน |
| `data-model-v1` | Group D |
