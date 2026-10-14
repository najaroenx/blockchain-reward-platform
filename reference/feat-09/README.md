# FEAT-09 · Delist

ร้านถอดรายการขายของตัวเองออกจาก marketplace

```text
pack09/
├── db/
│   ├── migration.sql       15 ตาราง · 39 index · 7 trigger · รันบน PG 16 ได้ตรงๆ
│   └── schema.prisma       สะท้อน migration · ตรวจแล้วตรงกัน 15/15 ตาราง 11/11 enum
├── api/
│   └── openapi.yaml        OpenAPI 3.1 · 2 path · 3 operation · 13 schema
├── src/
│   ├── types.ts            type ร่วม · brand type ของ base units
│   └── delist.service.ts   ชั้น ADMIT · tsc --strict ผ่าน 0 error
├── tests/
│   ├── acceptance.sql      34 ข้อรับประกัน
│   └── last-run.txt         ผลรันจริง
└── diagrams/
    ├── sequence.{mmd,svg}  ลำดับงานตั้งแต่กดถอดถึงคูปองกลับมา
    ├── er.{mmd,svg}        ความสัมพันธ์ของ 15 ตาราง
    └── state.{mmd,svg}     วงจรชีวิตของรายการขาย
```

## feature นี้มีอยู่เพื่ออะไร

ปิด `F5` โดยตรง

`delistMarketplaceListing.handler.ts` ของระบบเดิม เมื่อหา listing ไม่เจอ
โค้ดเซ็ต `ownerId = merchantId` เองแล้วเดินต่อ แปลว่า **"หาไม่เจอ" กลายเป็น
"ถือว่าเป็นของคนที่ขอ"** — ซึ่งทำให้การตรวจความเป็นเจ้าของหายไปทั้งก้อน

ที่นี่กลับกันสามข้อ

| ระบบเดิม | ที่นี่ |
|---|---|
| หาไม่เจอ → กรอกเจ้าของให้ | หาไม่เจอ → ปฏิเสธ |
| เจ้าของมาจากค่าที่คำขอส่งมา | เจ้าของมาจาก `actor_scope` ที่ผ่าน auth แล้ว |
| ตรวจที่ api layer | ตรวจที่ trigger บนตาราง `operation` |

ข้อที่สามสำคัญที่สุด · guard ในโค้ดข้ามได้ด้วยการเพิ่มเส้นทางใหม่อีกเส้น
(ระบบเดิมมี `/redeem-ais` แยกอีกเส้นจริงๆ — `F11`) แต่ trigger ข้ามไม่ได้
เพราะมันอยู่ชั้นเดียวกับที่เขียนข้อมูล

## กฎห้าข้อที่ย้ายลงฐานข้อมูล

| # | ชื่อ | ทำอะไร |
|---|---|---|
| 1 | `trg_delist_admissible` | ตรวจว่ารายการมีอยู่ · เป็นของผู้เรียก · สถานะ `ACTIVE` |
| 2 | `uq_listing_inflight` | รายการหนึ่งใบมีงานค้างได้ทีละงานเดียว · รวม `LISTING_BUY` ด้วย |
| 3 | `trg_listing_status_transition` | `DELISTED` และ `SOLD` เป็นปลายทาง · ย้อนกลับไม่ได้ |
| 4 | `trg_step_order_gate` | ขั้นที่ 2 ยิงได้เมื่อขั้นที่ 1 `FINALIZED` แล้ว |
| 5 | `trg_coupon_hold_until_closed` | ปิดรายการก่อน แล้วค่อยปล่อยคูปอง |

## สองขั้นที่สลับไม่ได้

```text
ลงขาย (FEAT-08)          approveCoupon → createListing → lockInVault
ถอด   (FEAT-09)          cancelListing → releaseFromVault
```

`cancelListing` ต้องมาก่อน · เอาคูปองออกจาก escrow ก่อนปิดรายการ
จะเปิดช่วงที่หน้า marketplace ยังโฆษณาของที่ไม่อยู่ใน escrow แล้ว
มีคนกดซื้อในช่วงนั้นได้ และ chain จะรับ tx ซื้อไปทั้งที่ไม่มีของจะส่งมอบ

ลำดับเดียวกันนี้บังคับสองชั้น

- ฝั่งงาน — `trg_step_order_gate` บน `operation_step`
- ฝั่งข้อมูล — `trg_coupon_hold_until_closed` บน `reservation`

สองชั้นเพราะ worker เขียนผิดลำดับได้ และ indexer ก็เขียนผิดลำดับได้
คนละ process กัน (`L2`) จึงไม่มีใครเห็นภาพรวมแทนกันได้

## การแข่งกับคนซื้อ · ส่วนที่คิดนานที่สุดของ feature นี้

ร้านกดถอดขณะลูกค้ากดซื้อ ไม่ใช่กรณีขอบ · เป็นสิ่งที่จะเกิดทุกวัน
และมันแข่งกันสองรอบ ไม่ใช่รอบเดียว

**รอบแรก ที่ฐานข้อมูล** — ใครแทรกแถว `operation` ได้ก่อนชนะ
`uq_listing_inflight` ให้ผู้ชนะหนึ่งคน ผู้แพ้ได้ `409 LISTING_BUSY`

**รอบสอง ที่ chain** — ชนะรอบแรกแล้วยังแพ้ได้
ถ้า tx ซื้อลงบล็อกก่อน `cancelListing` จะ revert
operation จบที่ `CHAIN_REVERTED` และรายการกลายเป็น `SOLD`

**FEAT-09 เป็น feature แรกที่ `CHAIN_REVERTED` เป็นผลลัพธ์ปกติ ไม่ใช่ error**

ของอื่นๆ ที่ revert แปลว่ามีอะไรผิด — ยอดไม่พอ สัญญาปฏิเสธ gas หมด
แต่ที่นี่ revert แปลว่า "มีคนซื้อไปแล้ว" ซึ่งเป็นผลลัพธ์ที่ถูกต้องสมบูรณ์
`markLostRace()` จึงไม่ย้อนอะไรเลย · คูปองคงอยู่ใน escrow ต่อ
เพราะมันต้องไปหาผู้ซื้อ ไม่ใช่กลับมาหาผู้ขาย — งานนั้นเป็นของ FEAT-10

## PENDING ถอดไม่ได้ · และนั่นถูกแล้ว

รายการที่ยัง `PENDING` ไม่มี `chain_listing_id` จะยกเลิกอะไรบน chain ไม่ได้
คำขอถอดได้ `409 LISTING_NOT_ACTIVE`

ร้านที่ติดอยู่ตรงนี้ต้องรอ — ซึ่งฟังดูไม่น่าพอใจ แต่ทางเลือกอื่นแย่กว่า
ถ้ายอมให้ยกเลิกคำขอที่ยังค้าง จะต้องตอบคำถามว่าถ้า `createListing`
ลงบล็อกหลังจากยกเลิกไปแล้วจะทำอย่างไร — ได้รายการที่ไม่มีใครเป็นเจ้าของ
บน chain `uq_listing_inflight` กันคำขอถอดไว้อยู่แล้วตั้งแต่ชั้น index
ไม่ต้องพึ่งเงื่อนไขสถานะด้วยซ้ำ

## คูปองไม่เคยเปลี่ยน state

ตลอดการลงขายและถอด `coupon_code.state` เป็น `HELD` และ `holder_id`
เป็นร้านเดิมเสมอ · การลงขายแสดงออกผ่าน `reservation` ไม่ใช่ผ่าน state

ทำให้เรื่องหนึ่งหายไปเลย — ไม่มี state ค้างกลางทางให้ต้องกู้
ถ้าถอดล้มกลางคัน ไม่มีอะไรต้องย้อน เพราะไม่มีอะไรถูกเปลี่ยน
มีแต่แถว `reservation` ที่ยังไม่ถูกปล่อย ซึ่งอ่านง่ายและกู้ง่าย

## 404 สองความหมาย

"ไม่พบรายการขาย" กับ "รายการนี้ไม่ใช่ของคุณ" คืน `404` เหมือนกัน
คนนอกจึงเดาไม่ได้ว่า `listingId` ไหนมีอยู่จริง

ฐานข้อมูลแยกสองกรณีได้ และข้อความจริงอยู่ใน log ของ server
`classifyAdmitError()` ใน service คือจุดที่สองกรณีถูกรวบเป็นคำตอบเดียว
และถ้าเจอข้อความที่ไม่รู้จัก มันตอบ `notFound` — ปฏิเสธเป็นค่าตั้งต้น

## ผลรันจริง

```text
psql -d feat09 -f db/migration.sql       15 ตาราง · 39 index · 7 trigger
psql -d feat09 -f tests/acceptance.sql   ผ่าน 34 · ไม่ผ่าน 0
openapi_spec_validator api/openapi.yaml  OpenAPI 3.1.0 VALID
prisma ↔ information_schema              15/15 ตาราง · 11/11 enum ตรงกัน
tsc --strict --noUncheckedIndexedAccess  0 error
mmdc sequence · er · state               3/3 render ผ่าน
```

T3 ถึง T8 คือ `F5` ในรูปของการทดสอบ และทั้งหกข้อถูกตรวจซ้ำว่า
error ที่ฐานข้อมูลคืนมาเป็นข้อความที่ตั้งใจจริง ไม่ใช่ผ่านเพราะเหตุอื่น

```text
T3 ของร้านอื่น      23514 · รายการขาย lst_b ไม่ใช่ของ merchant:mch_a
T4 ไม่มีอยู่         23514 · ไม่พบรายการขาย lst_ghost
T6 ลูกค้าถอดของร้าน  23514 · รายการขาย lst_a ไม่ใช่ของ customer:mch_a
T9 ยัง PENDING      23514 · รายการขาย lst_p อยู่สถานะ PENDING ถอดไม่ได้
T18 ข้ามลำดับ step   23514 · ขั้นที่ 2 ยิงไม่ได้ · ขั้นที่ 1 อยู่สถานะ PENDING
T21 ปล่อยตอน ACTIVE  23514 · ปล่อยคูปอง cc_1 ไม่ได้ · รายการขาย lst_a ยังอยู่สถานะ ACTIVE
```

T9 ถูกตรวจแยกในฐานข้อมูลที่ไม่มี operation ค้างเลย เพื่อยืนยันว่ามันถูก
ปฏิเสธด้วยเงื่อนไขสถานะจริง ไม่ใช่ไปชน `uq_listing_inflight` โดยบังเอิญ

## วิธีรัน

```bash
createdb feat09
psql -d feat09 -f db/migration.sql
psql -d feat09 -f tests/acceptance.sql     # ต้องได้ ผ่าน 34 · ไม่ผ่าน 0

npm i -D prisma typescript @types/node
export DATABASE_URL=postgres://localhost/feat09
npx prisma db pull                          # ตรวจว่า schema ตรงกัน
npx prisma generate
rm -rf typings/                             # แล้วเอา paths ออกจาก tsconfig.json
npx tsc --noEmit
```

`typings/@prisma/client.d.ts` เป็นตัวแทนชั่วคราวเพื่อให้ `tsc` ตรวจ `src/`
ได้ก่อน `prisma generate` · ลบทิ้งหลัง generate เสร็จ

## สิ่งที่ยังไม่ได้ตัดสิน

- ควรให้ร้านยกเลิกคำขอที่ยัง `PENDING` ได้ไหม · ตอนนี้ตอบว่าไม่ได้
  ถ้าจะให้ได้ ต้องมีกลไกจัดการ `createListing` ที่ลงบล็อกช้า
- `admin` ถอดได้ทุกใบ · ควรต้องมีเหตุผลแนบมาด้วยไหม
  ตอนนี้บันทึกแค่ว่าใครสั่ง (`operation_event.metadata.by`)
- รายการที่ค้างที่ `MANUAL_REVIEW` นานเกินกำหนด ควรปลดล็อกอัตโนมัติไหม
  ตอนนี้กันงานใหม่ไปเรื่อยๆ จนคนมาแก้
