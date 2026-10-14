# reference/ · dev pack ทั้ง 14 ชุด

**โฟลเดอร์นี้ไม่ใช่โค้ดของระบบ** เป็นเอกสารอ้างอิงที่เขียนขึ้นก่อนเริ่ม dev
ระบบจริงสร้างใหม่หมดใน `apps/` กับ `libs/`

## กฎสามข้อ

1. **ห้าม `import` อะไรจากในนี้** — ไม่มีไฟล์ไหนในนี้อยู่ใน build
2. **ห้ามแก้ไฟล์ในนี้** — เป็นหลักฐานว่า acceptance 366 ข้อเคยผ่าน ถ้าแก้แล้วหลักฐานหาย
   เจออะไรผิด ให้เปิด issue แทนการแก้ทับ
3. **ของที่ต้องใช้จริง ให้ copy ออกไปแล้วแก้ข้างนอก** — เช่นเอา `migration.sql` ทั้ง 14 ไฟล์
   ไปรวมเป็น schema เดียวใน `prisma/migrations/` (งาน BE-0002)

## ข้างในมีอะไร

แต่ละ `feat-NN/` หน้าตาเหมือนกันหมด

| path | คืออะไร | ใช้ตอนไหน |
|---|---|---|
| `README.md` | ที่มาที่ไปของ feature นั้น · การตัดสินใจที่สำคัญ | อ่านก่อนลงมือ |
| `db/migration.sql` | DDL ที่รันบน PostgreSQL 16 ได้ตรงๆ | BE-0002 รวม schema |
| `db/schema.prisma` | entity ที่ตรงกับ DDL ทุกคอลัมน์ | BE-0002 |
| `api/openapi.yaml` | OpenAPI 3.1 · validate ผ่าน · มี example จริง | งาน `type:api` ทุกใบ |
| `src/*.service.ts` | ชั้น ADMIT หรือ worker · `tsc --strict` ผ่าน | งาน `type:api` / `type:worker` |
| `src/types.ts` | type ที่ใช้ร่วม · branded type ของ id | ย้ายเข้า `libs/domain` |
| `tests/acceptance.sql` | ข้อรับประกันที่พิสูจน์ด้วย SQL จริง | BE-0003 harness |
| `tests/last-run.txt` | ผลรันครั้งล่าสุด PASS/FAIL ทุกแถว | เทียบว่าของเรายังผ่านอยู่ไหม |
| `diagrams/*.mmd` | sequence · ER · state (Mermaid) | หน้า wiki ใช้ชุดเดียวกันนี้ |

`feat-02/tests/contract-check.py` มีเพิ่มมาอีกไฟล์ · เป็นการตรวจว่าสูตรฝั่ง Python
กับฝั่ง SQL ให้ผลตรงกัน เป็นแบบของงาน BE-1004

## ตัวเลขของแต่ละ pack

| pack | ชื่อ | ตาราง | endpoint | acceptance |
|---|---|---|---|---|
| feat-01 | Merchant Onboarding | 11 | 3 | 14 PASS · 0 FAIL |
| feat-02 | Customer Register OTP | 14 | 3 | 39 PASS · 0 FAIL |
| feat-03 | Auth login token refresh | 7 | 5 | 15 PASS · 0 FAIL |
| feat-04 | Create Point Type | 12 | 4 | 17 PASS · 0 FAIL |
| feat-05 | Transfer Point | 15 | 3 | 20 PASS · 0 FAIL |
| feat-06 | Point Balance bucket expiry | 9 | 3 | 20 PASS · 0 FAIL |
| feat-07 | Coupon Type Issue | 12 | 4 | 23 PASS · 0 FAIL |
| feat-08 | List on Marketplace | 14 | 4 | 25 PASS · 0 FAIL |
| feat-09 | Delist | 15 | 3 | 34 PASS · 0 FAIL |
| feat-10 | Buy Coupon | 20 | 5 | 36 PASS · 0 FAIL |
| feat-11 | Redeem Coupon | 14 | 2 | 12 PASS · 0 FAIL |
| feat-12 | THB Deposit Mint | 16 | 4 | 34 PASS · 0 FAIL |
| feat-13 | Operation Status Webhook | 10 | 6 | 41 PASS · 0 FAIL |
| feat-14 | Indexer Projector | 13 | 4 | 36 PASS · 0 FAIL |
| | **รวม** | 180\* | **53** | **366 PASS · 0 FAIL** |

\* 180 คือผลบวกตรงๆ ตารางซ้ำกันข้าม pack เยอะ เหลือราว 49 ตารางหลังรวมเป็น schema เดียว
การรวมคืองาน BE-0002 และตัวเลขจริงจะรู้ตอนนั้น

## ที่โค้ดในนี้ยังไม่ได้ทำ

อ่านก่อนจะคิดว่า copy แล้วจบ

- **ไม่มี controller** — มีแต่ service layer การ map error เป็น HTTP code ต้องเขียนเอง
- **`Kms` เป็น interface เปล่า** — ตัวต่อ AWS KMS จริงคืองาน BE-0104
- **ไม่มี unit test ฝั่ง TypeScript เลย** — ที่ผ่าน 366 ข้อคือ SQL ล้วน ชั้น TS ยังไม่มีอะไรยืนยัน
- **worker กับ projector ส่วนใหญ่ยังไม่มี** — pack ที่มีมักมีแค่ชั้น ADMIT
- **`typings/@prisma/client.d.ts` ถูกถอดออกจากชุดนี้แล้ว** — เป็น stub ที่ pack ใช้ตอน type check
  ของจริงมาจาก `prisma generate`

## ตั้งค่าให้ไม่ปนกับ build

เติมบรรทัดเหล่านี้ (BE-0001 ทำไปแล้วถ้าทำตามใบ)

```gitignore
# .eslintignore / .prettierignore
reference/
```

```jsonc
// tsconfig.base.json
{ "exclude": ["reference/**"] }
```

```dockerignore
# .dockerignore
reference/
```
