# GitHub Project · Backlog board

สร้าง project พร้อมฟิลด์ แล้วยัด issue ทั้ง 125 ใบเข้าไปพร้อมเซ็ตค่าทุกฟิลด์ให้อัตโนมัติ

## เตรียมก่อน

```bash
brew install jq                       # ถ้ายังไม่มี
gh auth refresh -s project,read:project   # ให้สิทธิ์ project ครั้งเดียว
```

## รัน

```bash
unzip backoffice-project.zip -d project-pack
cd project-pack

# ซ้อมก่อน ไม่เรียก gh และไม่สร้างอะไร
DRY=1 OWNER=najaroenx REPO=najaroenx/blockchain-reward-platform bash scripts/create-github-project.sh

# ของจริง ใช้เวลาราว 5 ถึง 8 นาที
OWNER=najaroenx REPO=najaroenx/blockchain-reward-platform bash scripts/create-github-project.sh
```

รันซ้ำได้ ใบที่เพิ่มแล้วถูกจำไว้ใน `.project-map` แล้วจะถูกข้าม ถ้าหลุดกลางทางก็รันคำสั่งเดิมซ้ำ

ถ้าเคยรันเวอร์ชันก่อนหน้าแล้วขึ้น `ตัวเลือก ... ของฟิลด์ Risk ไม่มีอยู่` ทุกบรรทัด นั่นคือบั๊กของไฟล์ `project-items.tsv` เวอร์ชันเก่าที่ลงท้ายบรรทัดด้วย CRLF ทำให้ค่าช่องสุดท้ายติดอักขระขึ้นบรรทัดใหม่ · ชุดนี้แก้แล้ว ใช้ทับของเดิมแล้วรันใหม่ได้เลย project กับฟิลด์ที่สร้างไว้แล้วจะถูกใช้ต่อ ไม่สร้างซ้ำ

## ฟิลด์ที่จะได้

| ฟิลด์ | ชนิด | ค่า |
|---|---|---|
| `Status` | ของ GitHub เอง | ตั้งเป็น Todo ให้ทุกใบ |
| `Epic` | ตัวเลือก | EP-00 ถึง EP-10 |
| `Sprint` | ตัวเลือก | Sprint 1 ถึง Sprint 13 |
| `Kind` | ตัวเลือก | api · chain · epic · infra · migration · ops · policy · test · worker |
| `Risk` | ตัวเลือก | low · med · high |
| `Estimate` | ตัวเลข | point 1 2 3 5 8 ของแต่ละใบ |

ค่าทั้งหมดอ่านจาก `project-items.tsv` ซึ่งมาจาก backlog ชุดเดียวกับที่สร้าง issue ไป จึงตรงกันแน่นอน

## สามคลิกสุดท้ายที่ต้องกดเอง

GitHub ยังไม่เปิด API ให้สร้าง view ต้องกดในหน้า project

1. **Board** · view แรกเปลี่ยนเป็น Board แล้ว Group by = `Status` — ใช้ทำงานประจำวัน ลากการ์ดข้ามคอลัมน์
2. **Table** · New view > Table แล้ว Group by = `Epic` และเปิด Sum ที่คอลัมน์ `Estimate` — เห็นว่าแต่ละ epic กี่ point
3. **Roadmap** · New view > Roadmap แล้วตั้งแกนเป็น `Sprint` — ใช้คุยกับคนนอกทีม

อยากกรองเฉพาะ sprint ปัจจุบัน พิมพ์ในช่อง filter ว่า `sprint:"Sprint 1"` หรือกรองงานเสี่ยงสูงด้วย `risk:high`
