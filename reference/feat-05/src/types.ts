/**
 * FEAT-05 · Transfer Point · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type CustomerId = `cus_${string}`
export type PointTypeId = `pt_${string}`
export type OperationId = `op_${string}`

// ---------------------------------------------------------------- money
/** RFD 14 · จำนวนในหน่วยเล็กสุด ส่งเป็น string เสมอ ห้ามเป็น number */
export type BaseUnits = string & { readonly __brand: 'BaseUnits' }

export function toBaseUnits(v: string | bigint): BaseUnits {
  const s = typeof v === 'bigint' ? v.toString() : v
  if (!/^[0-9]+$/.test(s)) throw new RangeError(`ไม่ใช่ base units: ${s}`)
  return s as BaseUnits
}

export function isBaseUnits(v: unknown): v is BaseUnits {
  return typeof v === 'string' && /^[0-9]+$/.test(v)
}

/** คำนวณผ่าน bigint เสมอ · ห้ามแปลงเป็น number แม้ชั่วคราว */
export function sumBaseUnits(xs: readonly BaseUnits[]): BaseUnits {
  return toBaseUnits(xs.reduce((a, b) => a + BigInt(b), 0n))
}

/** แปลงเป็นหน่วยที่คนอ่าน · ใช้ได้ที่ชั้นแสดงผลเท่านั้น */
export function formatUnits(v: BaseUnits, decimals: number): string {
  const s = v.padStart(decimals + 1, '0')
  const whole = s.slice(0, s.length - decimals) || '0'
  const frac = decimals ? '.' + s.slice(s.length - decimals).replace(/0+$/, '') : ''
  return frac === '.' ? whole : whole + frac
}

// ---------------------------------------------------------------- enums
export type HolderKind = 'MERCHANT' | 'CUSTOMER'

export const OPERATION_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW',
] as const
export type OperationStatus = (typeof OPERATION_STATUS)[number]

export const STEP_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED', 'CHAIN_REVERTED', 'ORPHANED',
] as const
export type StepStatus = (typeof STEP_STATUS)[number]

/** เฉพาะ FINALIZED เท่านั้นที่แปลว่าโอนสำเร็จ (RFD 2 D9) */
export function isDone(s: OperationStatus): s is 'FINALIZED' {
  return s === 'FINALIZED'
}

/**
 * ปล่อยยอดที่จองไว้ได้เมื่อไหร่
 * MANUAL_REVIEW ยังปล่อยไม่ได้ · ต้องให้คนตัดสินก่อนว่าจบทางไหน
 * trigger `trg_reservation_release_timing` บังคับข้อนี้ที่ฐานข้อมูล
 */
export function canReleaseHold(s: OperationStatus): boolean {
  return s === 'FINALIZED' || s === 'CHAIN_REVERTED'
}

// --------------------------------------------------------------- batch
/** หนึ่ง tx รับผู้รับได้ไม่เกินเท่านี้ · เกินกว่านี้ gas เกิน block limit */
export const MAX_RECIPIENTS_PER_STEP = 100
/** หนึ่งคำขอรับผู้รับได้ไม่เกินเท่านี้ */
export const MAX_RECIPIENTS_PER_REQUEST = 1000

export function stepCountFor(recipients: number): number {
  return Math.ceil(recipients / MAX_RECIPIENTS_PER_STEP)
}

export function chunk<T>(xs: readonly T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < xs.length; i += size) out.push(xs.slice(i, i + size))
  return out
}

// ------------------------------------------------------- reservation key
/**
 * subject_id ของ POINT_BALANCE ต้องเป็นรูปแบบนี้เป๊ะ
 * trigger ในฐานข้อมูล split ด้วย `|` แล้ว cast เป็น enum
 * ถ้าโค้ดกับ trigger ใช้คนละรูปแบบ ยอดจะถูกนับแยกกันโดยไม่มีใครรู้
 */
export function pointBalanceKey(
  pointTypeId: PointTypeId,
  holderKind: HolderKind,
  holderId: string,
): string {
  return `${pointTypeId}|${holderKind}|${holderId}`
}

// ------------------------------------------------------------ epoch math
export interface EpochParams {
  genesisAt: Date
  epochSeconds: number
  validityEpochs: number
}

export function epochOf(p: EpochParams, t: Date): number {
  const delta = Math.floor((t.getTime() - p.genesisAt.getTime()) / 1000)
  return delta < 0 ? 0 : Math.floor(delta / p.epochSeconds)
}

/** RFD 10 · ขึ้นกับค่าคงที่ของ contract ไม่ขึ้นกับเวลาที่รัน จึง rebuild ได้ */
export function expiryOf(p: EpochParams, receivedAt: Date): Date {
  const end = (epochOf(p, receivedAt) + p.validityEpochs) * p.epochSeconds
  return new Date(p.genesisAt.getTime() + end * 1000)
}

// ------------------------------------------------------------- API shape
export interface Recipient {
  customerId: CustomerId
  amount: BaseUnits
}

export interface TransferRequest {
  pointTypeId: PointTypeId
  recipients: Recipient[]
  note?: string | null
}

export interface TransferAccepted {
  operationId: OperationId
  status: 'PENDING'
  pointTypeId: PointTypeId
  recipientCount: number
  totalAmount: BaseUnits
  stepCount: number
  reservedUntilFinal: true
}

export interface BucketView {
  amount: BaseUnits
  receivedAt: string
  expiresAt: string
}

export interface BalanceView {
  pointTypeId: PointTypeId
  holderKind: HolderKind
  holderId: string
  decimals: number
  available: BaseUnits
  reserved: BaseUnits
  /** เรียงตามวันหมดอายุ ใกล้ที่สุดก่อน */
  buckets: BucketView[]
}

export interface OperationStepView {
  index: number
  name: 'batchTransfer'
  recipientCount: number
  status: StepStatus
  txHash: string | null
  nonce: number | null
}

export interface OperationView {
  operationId: OperationId
  kind: 'POINT_TRANSFER'
  status: OperationStatus
  createdAt: string
  finalizedAt: string | null
  errorNote?: string | null
  steps: OperationStepView[]
}

export type ErrorCode =
  | 'IDEMPOTENCY_KEY_REQUIRED'
  | 'IDEMPOTENCY_KEY_REUSED'
  | 'IDEMPOTENCY_KEY_IN_PROGRESS'
  | 'VALIDATION_FAILED'
  | 'DUPLICATE_RECIPIENT'
  | 'INSUFFICIENT_POINTS'
  | 'POINT_TYPE_NOT_LIVE'
  | 'POINT_TYPE_NOT_FOUND'
  | 'FORBIDDEN'
  | 'RATE_LIMITED'

export interface ApiError {
  error: {
    code: ErrorCode
    message: string
    requestId: string
    details?: Record<string, unknown>
  }
}

export const RETRYABLE: ReadonlySet<ErrorCode> = new Set<ErrorCode>([
  'IDEMPOTENCY_KEY_IN_PROGRESS',
  'RATE_LIMITED',
])

export function isRetryable(e: ApiError): boolean {
  return RETRYABLE.has(e.error.code)
}

// ------------------------------------------------------- write path types
export type AdmitResult =
  | { outcome: 'created'; operationId: OperationId; stepCount: number; totalAmount: BaseUnits }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'conflict'; code: Extract<ErrorCode,
      'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS'> }
  | { outcome: 'insufficient'; requested: BaseUnits; available: BaseUnits }
