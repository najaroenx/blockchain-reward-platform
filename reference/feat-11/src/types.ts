/**
 * FEAT-11 · Redeem Coupon · shared types
 *
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 * กฎเดียวที่ type ระบบนี้บังคับแทนคน: จำนวนเงินห้ามเป็น `number` (RFD 14)
 */

// ---------------------------------------------------------------- money
/**
 * จำนวนในหน่วยเล็กสุด เป็น string ของเลขจำนวนเต็ม
 * branded เพื่อให้ `string` เปล่าๆ ใส่แทนไม่ได้ และ `number` ใส่ไม่ได้เลย
 */
export type BaseUnits = string & { readonly __brand: 'BaseUnits' }

const BASE_UNITS = /^[0-9]+$/

export function toBaseUnits(v: string | bigint): BaseUnits {
  const s = typeof v === 'bigint' ? v.toString() : v
  if (!BASE_UNITS.test(s)) throw new RangeError(`ไม่ใช่ base units: ${s}`)
  return s as BaseUnits
}

export function isBaseUnits(v: unknown): v is BaseUnits {
  return typeof v === 'string' && BASE_UNITS.test(v)
}

/** คำนวณต้องผ่าน bigint เสมอ · ห้ามแปลงเป็น number แม้ชั่วคราว */
export function addBaseUnits(a: BaseUnits, b: BaseUnits): BaseUnits {
  return toBaseUnits(BigInt(a) + BigInt(b))
}

/** แปลงเป็นหน่วยที่คนอ่าน · ใช้ได้ที่ชั้นแสดงผลเท่านั้น (RFD 14 D4) */
export function formatUnits(v: BaseUnits, decimals: number): string {
  const s = v.padStart(decimals + 1, '0')
  const whole = s.slice(0, s.length - decimals) || '0'
  const frac = decimals ? '.' + s.slice(s.length - decimals).replace(/0+$/, '') : ''
  return frac === '.' ? whole : whole + frac
}

// ------------------------------------------------------------- domain id
export type MerchantId = `mch_${string}`
export type CustomerId = `cus_${string}`
export type OperationId = `op_${string}`
export type CouponCodeId = `cc_${string}`
export type CouponTypeId = `ct_${string}`

// ---------------------------------------------------------------- enums
export const OPERATION_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW',
] as const
export type OperationStatus = (typeof OPERATION_STATUS)[number]

export const STEP_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED', 'CHAIN_REVERTED', 'ORPHANED',
] as const
export type StepStatus = (typeof STEP_STATUS)[number]

export const OPERATION_KIND = [
  'MERCHANT_PROVISION', 'POINT_TYPE_CREATE', 'POINT_TRANSFER',
  'COUPON_TYPE_CREATE', 'COUPON_ISSUE', 'COUPON_REDEEM',
  'LISTING_CREATE', 'LISTING_DELETE', 'LISTING_BUY', 'THB_MINT',
] as const
export type OperationKind = (typeof OPERATION_KIND)[number]

export type CouponCodeState = 'ISSUED' | 'HELD' | 'REDEEMED' | 'EXPIRED' | 'VOIDED'

/**
 * สถานะเดียวที่แสดงต่อผู้ใช้ได้ว่า "สำเร็จ" (RFD 2 D9)
 * CONFIRMED ยังย้อนได้เมื่อเกิด reorg
 */
export function isDone(s: OperationStatus): s is 'FINALIZED' {
  return s === 'FINALIZED'
}

export function isTerminal(s: OperationStatus): boolean {
  return s === 'FINALIZED' || s === 'CHAIN_REVERTED' || s === 'MANUAL_REVIEW'
}

// ------------------------------------------------------------- API shape
export interface RedeemRequest {
  /** Crockford base32 · ไม่มี I L O U */
  couponCode: string
  redeemedAtMerchantId?: MerchantId | null
}

export interface Settlement {
  amount: BaseUnits
  currency: string
  decimals: number
}

export interface RedeemAccepted {
  operationId: OperationId
  status: 'PENDING'
  couponCodeId: CouponCodeId
  settlement?: Settlement
}

export interface OperationStepView {
  index: number
  name: string
  status: StepStatus
  txHash: string | null
  nonce: number | null
}

export interface OperationView {
  operationId: OperationId
  kind: OperationKind
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
  | 'COUPON_NOT_FOUND'
  | 'COUPON_ALREADY_REDEEMED'
  | 'COUPON_LOCKED'
  | 'COUPON_EXPIRED'
  | 'ESCROW_INSUFFICIENT'
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

/** code ที่ retry ด้วย Idempotency-Key เดิมแล้วมีโอกาสสำเร็จ */
export const RETRYABLE: ReadonlySet<ErrorCode> = new Set<ErrorCode>([
  'IDEMPOTENCY_KEY_IN_PROGRESS',
  'COUPON_LOCKED',
  'RATE_LIMITED',
])

export function isRetryable(e: ApiError): boolean {
  return RETRYABLE.has(e.error.code)
}

// ------------------------------------------------------- write path types
export interface AdmitInput {
  scope: string
  idempotencyKey: string
  fingerprint: Buffer
  kind: OperationKind
  payload: unknown
  /** หนึ่งรายการต่อหนึ่ง chain tx · ลำดับคือลำดับที่ต้องยิง */
  steps: { name: string }[]
  /** ของที่ต้องกันไว้ระหว่างรอ chain */
  reservations: { subjectType: ReservationSubject; subjectId: string; amount: BaseUnits }[]
  /** topic ของ outbox · ใส่เวอร์ชันในชื่อเสมอ (RFD 7 D9) */
  topic: `${string}.v${number}`
}

export type ReservationSubject =
  | 'POINT_BALANCE' | 'COUPON_UNIT' | 'LISTING' | 'THB_BALANCE' | 'ESCROW'

export type AdmitResult =
  | { outcome: 'created'; operationId: OperationId }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'conflict'; code: Extract<ErrorCode, 'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS'> }
