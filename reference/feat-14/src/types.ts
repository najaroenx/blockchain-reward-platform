/**
 * FEAT-14 · Indexer + Projector · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 *
 * ข้อสังเกตที่ต่างจากทุก pack ก่อนหน้า
 *   ตรรกะหลักของ pack นี้อยู่ในฟังก์ชันของฐานข้อมูล ไม่ใช่ในไฟล์นี้
 *   ไฟล์นี้จึงเล็กกว่าที่ควร และนั่นถูกแล้ว
 *   การ replay ต้องใช้ตรรกะเดียวกับการ apply ครั้งแรกเป๊ะ
 *   ถ้าตรรกะอยู่ที่นี่ การ replay จะต้องรันโค้ดรุ่นเดียวกับที่ apply ครั้งแรก
 *   ซึ่งเป็นไปไม่ได้เมื่อเวลาผ่านไปและโค้ดเปลี่ยน
 */

// ------------------------------------------------------------ domain id
export type EventId = `ce_${string}`
export type ReorgId = `rg_${string}`
export type OperationId = `op_${string}`

export type Hash32 = `0x${string}`
export type Address = `0x${string}`

// ---------------------------------------------------------------- enums
export const CHAIN_EVENT_NAME = [
  'CouponTransfer', 'PointTransfer', 'CouponRedeemed', 'UNKNOWN',
] as const
export type ChainEventName = (typeof CHAIN_EVENT_NAME)[number]

export type ReorgOutcome = 'ROLLED_BACK' | 'MANUAL_REVIEW'
export type HolderKind = 'MERCHANT' | 'CUSTOMER'

/** ชนิดที่ถอดรหัสได้ ต้องมี args · ตรงกับ ck_known_has_args */
export function isDecodable(n: ChainEventName): boolean {
  return n !== 'UNKNOWN'
}

// =================================================== การนับความลึก
/**
 * event นี้ลึกพอที่จะถือว่าจบหรือยัง
 *
 * RFD 5 · การ "นับความลึก" ใช้ตัดสินว่า final ได้ แต่ใช้ตรวจ reorg ไม่ได้
 * สองเรื่องนี้ต่างกัน และสับสนกันได้ง่าย
 *
 *   ตรวจ reorg    เทียบ block_hash · ความลึกบอกอะไรไม่ได้เลย
 *                 เพราะสายที่ยาวกว่าอาจเป็นสายอื่น
 *   ตัดสิน final  นับความลึก · เพราะคำถามคือ "ยากแค่ไหนที่จะย้อน"
 */
export function isFinal(
  eventBlock: bigint,
  tipBlock: bigint,
  depthBlocks: number,
): boolean {
  return eventBlock <= tipBlock - BigInt(depthBlocks)
}

/** ความลึกของ reorg · ตรงกับ ck_depth_matches */
export function reorgDepth(forkBlock: bigint, oldTip: bigint): number {
  if (forkBlock > oldTip)
    throw new RangeError(`fork ${forkBlock} อยู่หลัง tip ${oldTip} · ไม่ใช่ reorg`)
  return Number(oldTip - forkBlock) + 1
}

/**
 * ผลลัพธ์ของ reorg · คำนวณจากความลึกและว่ามี event final อยู่ในช่วงไหม
 * ตรงกับ f_handle_reorg และ trg_reorg_outcome_matches_depth
 *
 * เลือกเองไม่ได้ทั้งสองทิศทาง — ลึกเกิน N แต่อ้าง ROLLED_BACK ก็ถูกปฏิเสธ
 * และไม่เกิน N แต่อ้าง MANUAL_REVIEW ก็ถูกปฏิเสธ
 */
export function reorgOutcomeFor(
  depth: number,
  finalityDepth: number,
  finalEventsInRange: number,
): ReorgOutcome {
  if (depth > finalityDepth || finalEventsInRange > 0) return 'MANUAL_REVIEW'
  return 'ROLLED_BACK'
}

// =================================================== ลำดับของ event
/**
 * ลำดับจริงบน chain · (block_number, log_index)
 * f_apply_pending เรียงตามนี้ และลำดับนี้สำคัญ
 *
 * สลับลำดับของ PointTransfer สองแถวในบล็อกเดียว อาจทำให้ยอดติดลบกลางทาง
 * แล้ว CHECK (amount >= 0) ปฏิเสธ ทั้งที่ผลสุดท้ายถูก
 */
export interface EventPosition {
  blockNumber: bigint
  logIndex: number
}

export function comparePosition(a: EventPosition, b: EventPosition): number {
  if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1
  return a.logIndex - b.logIndex
}

export function isInChainOrder(events: readonly EventPosition[]): boolean {
  for (let i = 1; i < events.length; i++) {
    const prev = events[i - 1]
    const cur = events[i]
    if (!prev || !cur) return false
    if (comparePosition(prev, cur) >= 0) return false
  }
  return true
}

// =================================================== สายโซ่ของบล็อก
export interface BlockHeader {
  blockNumber: bigint
  blockHash: Hash32
  parentHash: Hash32
}

/**
 * RFD 5 · สายโซ่ต้องต่อกัน · ตรงกับ trg_block_links_to_parent
 *
 * คืนความสูงของบล็อกแรกที่ขาด หรือ null ถ้าต่อกันครบ
 * ค่าที่คืนมาคือจุดที่ต้องเริ่ม orphan ไม่ใช่แค่สัญญาณว่ามีปัญหา
 */
export function findForkPoint(chain: readonly BlockHeader[]): bigint | null {
  for (let i = 1; i < chain.length; i++) {
    const prev = chain[i - 1]
    const cur = chain[i]
    if (!prev || !cur) return null
    if (cur.blockNumber !== prev.blockNumber + 1n) return cur.blockNumber
    if (cur.parentHash !== prev.blockHash) return cur.blockNumber
  }
  return null
}

// ------------------------------------------------------------- API shape
export interface IndexerStatus {
  lastBlock: number
  lastBlockHash: Hash32 | null
  chainHead: number
  lagBlocks: number
  leaseHeldBy: string | null
  leaseUntil: string | null
  finalityDepth: number
  pendingEvents: number
}

/**
 * indexer ตามหลังมากเกินไปหรือยัง
 * ตั้ง alert ที่ lagBlocks ไม่ใช่ที่ lastBlock
 * เพราะ lastBlock เดินหน้าอยู่เสมอก็ยังตามไม่ทันได้
 */
export function isLagging(s: IndexerStatus, maxLag = 50): boolean {
  return s.lagBlocks > maxLag
}

/** ไม่มีใครถือ lease = ไม่มีใครอ่าน chain · ต้องรู้ทันที */
export function hasNoWorker(s: IndexerStatus, now = new Date()): boolean {
  if (s.leaseHeldBy === null || s.leaseUntil === null) return true
  return Date.parse(s.leaseUntil) <= now.getTime()
}

export interface PendingEvent {
  eventId: EventId
  blockNumber: number
  logIndex: number
  eventName: ChainEventName
  txHash: Hash32
}

export interface ReorgView {
  reorgId: ReorgId
  detectedAt: string
  forkBlock: number
  oldTip: number
  depth: number
  finalityDepth: number
  orphanedEvents: number
  outcome: ReorgOutcome
  note: string | null
}

export function needsHumanReview(r: ReorgView): boolean {
  return r.outcome === 'MANUAL_REVIEW'
}

// --------------------------------------------------- args ของแต่ละชนิด
export interface CouponTransferArgs {
  codeRef: string
  toKind: HolderKind
  toId: string
}

export interface PointTransferArgs {
  pointTypeId: string
  toKind: HolderKind
  toId: string
  amount: string
  /** ว่าง = mint · ไม่มีคนจ่าย */
  fromId: string
  fromKind?: HolderKind
}

export interface CouponRedeemedArgs {
  codeRef: string
}

export type EventArgs =
  | { name: 'CouponTransfer'; args: CouponTransferArgs }
  | { name: 'PointTransfer'; args: PointTransferArgs }
  | { name: 'CouponRedeemed'; args: CouponRedeemedArgs }
  | { name: 'UNKNOWN'; args: null }

/**
 * ตรวจว่า args ครบตามชนิด · ทำที่โค้ดเพราะ jsonb ตรวจรูปร่างไม่ได้
 * ฐานข้อมูลตรวจได้แค่ว่า args ไม่เป็น NULL (ck_known_has_args)
 */
export function argsAreComplete(e: EventArgs): boolean {
  switch (e.name) {
    case 'CouponTransfer':
      return !!e.args.codeRef && !!e.args.toKind && !!e.args.toId
    case 'PointTransfer':
      return !!e.args.pointTypeId && !!e.args.toId && /^[0-9]+$/.test(e.args.amount)
        && (e.args.fromId === '' || !!e.args.fromKind)
    case 'CouponRedeemed':
      return !!e.args.codeRef
    case 'UNKNOWN':
      return e.args === null
  }
}
