# FEAT-14 · Indexer + Projector

อ่าน log จาก chain แล้วแปลงเป็นตารางที่ api อ่านได้

```text
pack14/
├── db/
│   ├── migration.sql       13 ตาราง · 24 index · 5 trigger · 11 ฟังก์ชัน
│   └── schema.prisma       ตรวจแล้วตรงกัน 13/13 ตาราง 7/7 enum
├── api/
│   └── openapi.yaml        OpenAPI 3.1 · 4 path · 6 schema (ของฝ่าย ops)
├── src/
│   ├── types.ts            การนับความลึก · หาจุดแยก · ลำดับของ event
│   └── indexer.service.ts  acquire · readNext · handleReorg · replay
├── tests/
│   ├── acceptance.sql      36 ข้อรับประกัน
│   └── last-run.txt         ผลรันจริง
└── diagrams/
    ├── sequence.{mmd,svg}  อ่านบล็อก · apply · จัดการ reorg · replay
    ├── er.{mmd,svg}        ความสัมพันธ์ของ 13 ตาราง
    └── state.{mmd,svg}     วงจรชีวิตของ chain_event หนึ่งแถว
```

pack นี้เป็นฝั่งตรงข้ามของทุก pack ก่อนหน้า — pack อื่นเขียน `operation`
แล้วยิง tx ออกไป · pack นี้อ่านผลที่กลับมาแล้วเขียน projection

## สามข้อที่ pack นี้ต้องทำให้เป็นจริง

| ข้อ | กลไก | ทดสอบ |
|---|---|---|
| `L8` indexer เดียว | แถวเดียว + lease + advisory lock | T2–T6 |
| `L8` cursor ขยับพร้อม event | `trg_event_within_cursor` ตรวจตอน `COMMIT` | T11–T12 |
| `RFD 5` reorg ด้วย hash | `trg_block_links_to_parent` | T7–T10 |
| `RFD 6 §3.2` replay ได้ | `f_replay_projections()` | **T20–T23** |

## RFD 6 §3.2 · พิสูจน์แล้ว ไม่ใช่อ้าง

ทุก pack ก่อนหน้าอ้างกฎนี้ — *ลบ projection ทิ้ง แล้ว replay `chain_event`
ใหม่ ต้องได้ค่าเดิมเป๊ะ* — แต่ไม่มีใครพิสูจน์

T20 ถึง T23 ทำจริง

```sql
CREATE TEMP TABLE snap_holding AS SELECT * FROM coupon_holding;
SELECT f_replay_projections();        -- ลบ · ล้าง applied_at · apply ใหม่
-- แล้วเทียบด้วย EXCEPT ทั้งสองทิศทาง · ต้องได้ 0 แถว
```

เทียบ **ทุกคอลัมน์ทุกแถว** ด้วย `EXCEPT` สองทิศทาง ไม่ใช่เทียบจำนวนแถว

### และพิสูจน์ว่าการทดสอบนั้นจับได้จริง

การทดสอบที่ผ่านเสมอไม่มีค่า จึงทดลองทำให้ผิดจริงแล้วดูว่ามันจับได้ไหม
แก้ `f_apply_event` จุดเดียว — `e.block_timestamp` → `clock_timestamp()`
ซึ่งคือการเอาเวลาที่ apply มาใส่ใน projection แทนเวลาของบล็อก

```text
T20  RFD 6 · ลบแล้ว replay · coupon_holding เหมือนเดิมเป๊ะ       FAIL
T21  RFD 6 · ลบแล้ว replay · point_balance เหมือนเดิมเป๊ะ        PASS
T22  RFD 6 · state ของ coupon_code เหมือนเดิมเป๊ะ               PASS
T23  as_of_time มาจาก block ไม่ใช่เวลาที่ apply                   FAIL
T25  หลัง reorg · projection กลับไปเหมือน snapshot               FAIL
```

สามข้อ FAIL · และ T21 T22 ยัง PASS เพราะทดสอบ projection ที่ไม่ได้ถูกแก้
นั่นคือพฤติกรรมที่ถูก — การทดสอบเจาะจง ไม่ใช่เหวี่ยง

**กฎที่ตามมาและสำคัญกว่าที่เห็น** — ตาราง projection ห้ามมีคอลัมน์ที่ค่า
มาจากเวลาที่ apply · `now()` ในตารางพวกนี้ทำให้ replay ได้ค่าต่างทันที

### `state` ของ `coupon_code` ก็เป็น projection

ข้อนี้พลาดได้ง่ายที่สุด เพราะตารางนี้ไม่ได้ชื่อว่าเป็น projection
และอยู่ในกลุ่มที่ดูเหมือนข้อมูลตัวตน แต่ `CouponRedeemed` เขียนทับมัน
`f_replay_projections()` จึงต้องย้อนค่านี้กลับไป `ISSUED` ก่อน apply ใหม่ (T22)

บทเรียน — "เป็น projection หรือไม่" ตัดสินจาก *มีใครเขียนจาก chain ไหม*
ไม่ใช่จากชื่อตารางหรือกลุ่มที่มันอยู่

## L8 · indexer เดียว · สองชั้นและทั้งสองจำเป็น

| ชั้น | กันอะไร | ไม่กันอะไร |
|---|---|---|
| `pg_try_advisory_lock` | สอง process ที่ยังมีชีวิตพร้อมกัน | process ที่แฮงค์ · connection ยังอยู่ lock จึงยังถือ |
| `lease_until` | process ที่หยุดตอบสนอง | สอง process ที่เร็วพอๆ กันแย่งกันขยับ |

ชั้นเดียวไม่พอทั้งสองทาง · `trg_cursor_needs_lease` บังคับสามข้อ

- ไม่มี lease ขยับไม่ได้ (T2)
- lease หมดอายุขยับไม่ได้ (T3)
- เปลี่ยนเจ้าของ lease พร้อมกับขยับในสเตตเมนต์เดียวไม่ได้ (T4)

ข้อที่สามกันช่องที่แคบแต่มีจริง — ถ้าทำสองเรื่องในสเตตเมนต์เดียวได้
process ที่เพิ่งแย่ง lease มาจะขยับ cursor ได้ทันทีโดยยังไม่รู้ว่า
cursor อยู่ไหน ต้องแยกเป็นสองสเตตเมนต์ เพื่อให้อ่านสถานะก่อนเขียน

## L8 ข้อสอง · เขียนเป็นกฎที่ตรวจได้

"cursor ขยับใน transaction เดียวกับการ insert `chain_event`"
เป็นประโยคที่ตรวจตรงๆ ไม่ได้ · จึงแปลงเป็นข้อที่ตรวจได้

> ไม่มี `chain_event` ที่ `block_number` เกิน `cursor.last_block`

ถ้ามี แปลว่ามีใคร insert event แล้วไม่ขยับ cursor ใน transaction เดียวกัน
ตรวจตอน `COMMIT` เพราะลำดับการเขียนไม่แน่ — บางที่ขยับ cursor ก่อน
บางที่ insert event ก่อน ทั้งสองแบบถูก ขอแค่ตอน `COMMIT` มันสอดคล้อง

## RFD 5 · reorg ตรวจด้วย hash ไม่ใช่นับความลึก

`trg_block_links_to_parent` ทำให้ **สายโซ่ที่ขาดเก็บลงฐานข้อมูลไม่ได้เลย**
ไม่ใช่เก็บได้แล้วค่อยมีใครมาตรวจทีหลัง (T7)

```text
ERROR:  บล็อก 21 ชี้ไป parent 4a7f… แต่บล็อก 20 ที่มีอยู่คือ 9c2e…
HINT:  นี่คือ reorg · ต้อง orphan บล็อกเก่าก่อน แล้วค่อยเขียนบล็อกใหม่
```

### สองเรื่องที่สับสนกันง่าย

| คำถาม | วิธีตอบ | ทำไม |
|---|---|---|
| มี reorg ไหม | เทียบ `block_hash` | ความลึกบอกอะไรไม่ได้ · สายที่ยาวกว่าอาจเป็นสายอื่น |
| จบแล้วหรือยัง | นับความลึก | คำถามคือ "ยากแค่ไหนที่จะย้อน" |

การนับความลึกใช้ตัดสิน final ได้ แต่ใช้ตรวจ reorg ไม่ได้
และ `_FACTS.md` เขียนไว้แล้วว่า "เทียบซ้ำ ไม่ใช่นับความลึก" — หมายถึงข้อแรก

## ค่า N · คำถามที่ RFD 1 §10 ค้างไว้

pack นี้ **ไม่ได้ตอบว่า 12 ถูกหรือผิด** · ตอบแค่สองข้อ

1. ค่านี้อยู่ที่เดียว — ตาราง `finality_config` ไม่ใช่ค่าคงที่กระจายในโค้ด
2. เปลี่ยนค่าวันนี้ไม่ทำลายอดีต — `f_finality_depth(ts)` ตอบตามเวลาที่ถาม (T32)

และทำให้ค่านั้น**มีความหมาย** — `trg_final_not_orphanable` ปฏิเสธการ orphan
event ที่ `finalized_at` ถูกตั้งแล้ว (T27)

```text
ERROR:  event ce_t1 ถือว่า final ไปแล้วตั้งแต่ … · orphan ไม่ได้
HINT:  reorg ที่ลึกกว่า N ต้องไป MANUAL_REVIEW ไม่ใช่ย้อนเงียบๆ
```

ถ้า event ที่บอกลูกค้าว่าเสร็จแล้วยังหลุดได้ ค่า N ก็ไม่มีความหมายเลย

## จัดการ reorg โดยไม่ย้อนทีละ event

`f_handle_reorg` ไม่พยายามย้อน event แบบทำตรงข้าม เพราะบาง event
ย้อนตรงๆ ไม่ได้ — `CouponRedeemed` ลบแถวใน `coupon_holding`
จะรู้ได้อย่างไรว่าเดิมใครถือ

จึง **orphan แล้ว replay ทั้งหมดใหม่** · ช้ากว่า แต่ถูกเสมอ
และใช้ตรรกะเดียวกับ apply ปกติ ซึ่งแปลว่า**ไม่มีโค้ดเส้นที่สองที่ต้องดูแล
ให้ตรงกับเส้นแรก** — โค้ดย้อนกลับที่ไม่ค่อยได้รันคือโค้ดที่พังเงียบๆ

ผลลัพธ์เลือกเองไม่ได้ · `trg_reorg_outcome_matches_depth` ปฏิเสธทั้งสองทิศทาง
แบบเดียวกับการตีกลับใน FEAT-12 (T30)

## ตรรกะอยู่ในฐานข้อมูล ไม่ใช่ใน TypeScript

`src/` ของ pack นี้บางกว่าทุก pack ก่อนหน้า และนั่นถูกแล้ว

`f_apply_event` อยู่ในฐานข้อมูลเพราะ **การ replay ต้องใช้ตรรกะเดียวกับ
การ apply ครั้งแรกเป๊ะ** · ถ้าตรรกะอยู่ในโค้ด การ replay จะต้องรันโค้ด
รุ่นเดียวกับที่ apply ครั้งแรก ซึ่งเป็นไปไม่ได้เมื่อ deploy ใหม่

อยู่ในฐานข้อมูลก็ยังเป็นปัญหาเดียวกันในทางทฤษฎี — ฟังก์ชันเปลี่ยนได้
แต่เล็กกว่ามากในทางปฏิบัติ และทำให้ T20–T23 ทดสอบสิ่งที่ production ทำจริง
ไม่ใช่ทดสอบโค้ดคนละชุดกับที่รันอยู่

`openapi.yaml` ของ pack นี้บอกไว้ชัดว่า `replay` จะให้ **ค่าตามตรรกะวันนี้**
ไม่ใช่ค่าเดิม ถ้าฟังก์ชันเปลี่ยนไปแล้ว · ซึ่งมักเป็นสิ่งที่ต้องการ แต่ไม่ใช่ทุกครั้ง

## ผลรันจริง

```text
psql -d feat14 -f db/migration.sql        13 ตาราง · 24 index · 5 trigger
psql -d feat14 -f tests/acceptance.sql    ผ่าน 36 · ไม่ผ่าน 0
openapi_spec_validator api/openapi.yaml   OpenAPI 3.1.0 VALID
prisma ↔ information_schema               13/13 ตาราง · 7/7 enum ตรงกัน
tsc --strict --noUncheckedIndexedAccess   0 error
reorgDepth · reorgOutcomeFor ↔ SQL        ตรงกัน 4/4 เคส
isFinal() ↔ f_mark_finalized              ตรงกัน
mutation test · ทำให้ผิดจริง               T20 T23 T25 FAIL ตามที่ควร
mmdc sequence · er · state                3/3 render ผ่าน
```

## บั๊กที่การทดสอบจับได้ · และเป็นบั๊กเชิงแบบจำลอง

T26 FAIL รอบแรกด้วย `duplicate key value violates "raw_block_pkey"`

ผมตั้ง `block_number` เป็น primary key ของ `raw_block` และเพิ่ม
partial unique index `uq_block_live` ไว้ด้วย โดยคิดว่าจะได้
"หนึ่งความสูงมีบล็อกบนสายหลักได้ใบเดียว แต่ที่ orphan แล้วมีได้หลายใบ"

สองข้อนั้นขัดกันเอง · primary key บน `block_number` ทำให้ความสูงเดียวกัน
มีได้ใบเดียวเสมอ ไม่ว่าจะ orphan หรือไม่ — ซึ่งทำให้ **reorg เก็บประวัติไม่ได้เลย**
ต้องลบบล็อกเก่าทิ้งก่อนเขียนใบใหม่ และเมื่อลบทิ้งก็สืบย้อนไม่ได้ว่าเคยเชื่ออะไร

> **ตัวตนของบล็อกคือ hash ของมัน · ความสูงไม่ใช่ตัวตน**

เปลี่ยน primary key เป็น `block_hash` · ความสูงเหลือเป็น index ธรรมดา
บวก `uq_block_live` ที่ทำงานได้จริงแล้ว (T26 ตรวจว่าความสูง 45 มีสองใบ)

ข้อนี้ไม่ใช่บั๊กการพิมพ์ผิด · เป็นการเข้าใจโมเดลผิด และการทดสอบที่
สร้างสถานการณ์ reorg จริงเป็นสิ่งเดียวที่จับได้

## อีกเรื่องที่พลาดและใช้เวลาไล่นาน

T27 T28 T29 FAIL พร้อมกัน และสาเหตุไม่ได้อยู่ในสามข้อนั้นเลย

ฉากของผมอ่านบล็อกถึง 30 แล้ววาง event ไว้ที่บล็อก 22–25
`N` คือ 12 · tip 30 → final ถึงบล็อก 18 เท่านั้น
**ไม่มี event ไหนในฉากที่ final เลย** T27 ("orphan event ที่ final ไม่ได้")
จึง orphan สำเร็จและ FAIL · แล้วมันทิ้งสถานะที่ผิดไว้ให้ T28 T29 ต่อ

แก้โดยอ่านบล็อกถึง 45 ให้ event ชุดแรกกลายเป็น final จริง

บทเรียน — การทดสอบที่ "ผ่านโดยไม่ได้ทดสอบอะไร" กับการทดสอบที่ FAIL
ดูไม่ต่างกันจากภายนอก · T27 ถ้าเขียนกลับด้าน (คาดว่า orphan สำเร็จ)
มันจะ PASS ทุกครั้งและไม่มีใครรู้ว่ากฎนั้นไม่เคยถูกทดสอบ
ตอนนี้ T27 เช็ค `finalized_at IS NULL` ก่อน แล้ว FAIL ทันทีถ้าฉากไม่ถูก

## วิธีรัน

```bash
createdb feat14
psql -d feat14 -f db/migration.sql
psql -d feat14 -f tests/acceptance.sql     # ต้องได้ ผ่าน 36 · ไม่ผ่าน 0

npm i -D prisma typescript @types/node
export DATABASE_URL=postgres://localhost/feat14
npx prisma db pull
npx prisma generate
rm -rf typings/
npx tsc --noEmit
```

ก่อนเริ่มอ่าน chain ต้องมีสองแถวนี้

```sql
INSERT INTO finality_config (id, depth_blocks, effective_from)
VALUES ('fin_v1', 12, now());
INSERT INTO indexer_cursor (id, last_block) VALUES ('main', 0);
```

ไม่มี `indexer_cursor` แล้ว `trg_event_within_cursor` จะปฏิเสธทุกการ insert
พร้อมข้อความว่าต้องสร้างก่อน — โดยตั้งใจ · เริ่มอ่านโดยไม่มีที่จดว่าอ่านถึงไหน
คือการเริ่มในสภาพที่กู้ไม่ได้

## สิ่งที่ยังไม่ได้ตัดสิน

- **ค่า `N` = 12 ยังไม่ผ่านการยืนยันกับทีม chain** · pack นี้ทำให้ค่านี้
  อยู่ที่เดียวและเปลี่ยนได้โดยไม่ทำลายอดีต แต่ไม่ได้บอกว่าควรเป็นเท่าไร
- **`MANUAL_REVIEW` แล้วอย่างไรต่อ** · ตอนนี้บันทึกใน `reorg_log` แล้วหยุด
  indexer จะค้างอยู่ที่เดิมเพราะเขียนบล็อกใหม่ไม่ได้ (สายโซ่ไม่ต่อ)
  ซึ่งถูกแล้วในแง่ความปลอดภัย แต่ยังไม่มีเครื่องมือให้คนแก้
- **`f_replay_projections` ล็อกอะไรหรือเปล่า** · ตอนนี้ไม่ล็อก
  ถ้ารันพร้อมกับ projector ปกติจะชนกัน · ควรใช้ advisory lock ตัวเดียวกับ indexer
  แต่ยังไม่ได้ทำ เพราะต้องตอบก่อนว่า replay ควรหยุด indexer หรือรอให้ว่าง
- **`decodeLog` ยังเป็นโครง** · ของจริงต้องเทียบ `topic0` กับ `keccak256`
  ของ signature ใน ABI · pack นี้ทดสอบ schema ไม่ได้ทดสอบการถอดรหัส
  และ `args` ที่ใช้ในเทสต์ถูกใส่มือ ไม่ได้ถอดจาก `data` จริง
- **เพดานของการเดินย้อนหาจุดแยก** ตอนนี้ 200 บล็อก · เกินกว่านั้นโยน error
  ซึ่งถูกกว่าการเดินไปเรื่อยๆ แต่ยังไม่ได้ตอบว่า 200 มาจากไหน
