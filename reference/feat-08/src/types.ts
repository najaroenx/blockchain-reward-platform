/**
 * FEAT-08 · List on Marketplace · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type CouponTypeId = `ct_${string}`
export type CouponCodeId = `cc_${string}`
export type ListingId = `lst_${string}`
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

/**
 * ราคารวม = ราคาต่อใบ × จำนวน
 * ต้องผ่าน bigint · ราคาต่อใบ 80e18 คูณ 500 ใบ เกิน 2^53 ไปไกลมาก
 */
export function totalPriceOf(unitPrice: BaseUnits, quantity: number): BaseUnits {
  return toBaseUnits(BigInt(unitPrice) * BigInt(quantity))
}

// ---------------------------------------------------------------- enums
export type HolderKind = 'MERCHANT' | 'CUSTOMER'

export const LISTING_STATUS = ['PENDING', 'ACTIVE', 'SOLD', 'DELISTED', 'FAILED'] as const
export type ListingStatus = (typeof LISTING_STATUS)[number]

export const OPERATION_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW',
] as const
export type OperationStatus = (typeof OPERATION_STATUS)[number]

export type StepStatus =
  'PENDING' | 'SUBMITTED' | 'CONFIRMED' | 'FINALIZED' | 'CHAIN_REVERTED' | 'ORPHANED'

/** ซื้อได้หรือยัง */
export function isBuyable(s: ListingStatus): s is 'ACTIVE' {
  return s === 'ACTIVE'
}

/** เฉพาะ FINALIZED เท่านั้นที่แปลว่ารายการขายใช้งานได้ (RFD 2 D9) */
export function isDone(s: OperationStatus): s is 'FINALIZED' {
  return s === 'FINALIZED'
}

/** RFD 9 · ปล่อยคูปองที่กันไว้ได้เมื่องานจบแล้วเท่านั้น */
export function canReleaseHold(s: OperationStatus): boolean {
  return s === 'FINALIZED' || s === 'CHAIN_REVERTED'
}

// ====================================================== สามขั้นของการลงขาย
/**
 * ลงขายหนึ่งครั้ง = สาม tx ที่ต้องเรียงกัน (RFD 2 §3.5 D4)
 * ลำดับนี้ห้ามสลับ · approve ก่อนถึงจะ createListing ได้
 * และต้องมี listing บน chain ก่อนถึงจะ lock เข้า vault ได้
 */
export const LISTING_STEPS = ['approveCoupon', 'createListing', 'lockInVault'] as const
export type ListingStepName = (typeof LISTING_STEPS)[number]
export const LISTING_STEP_COUNT = LISTING_STEPS.length

/** หนึ่งรายการขายรับได้ไม่เกินเท่านี้ใบ */
export const MAX_CODES_PER_LISTING = 500

// ------------------------------------------------------- reservation key
/**
 * ของชิ้นเดียวใช้ id ของมันเป็น subject_id ตรงๆ
 * uq_reservation_exclusive ครอบ COUPON_UNIT และ LISTING จึงกันการจองซ้อนให้เอง
 */
export function couponUnitKey(codeId: CouponCodeId): string {
  return codeId
}

export function listingKey(listingId: ListingId): string {
  return listingId
}

// ------------------------------------------------------------- API shape
export interface CreateListingRequest {
  couponTypeId: CouponTypeId
  unitPrice: BaseUnits
  couponCodeIds: CouponCodeId[]
}

export interface ListingChainView {
  contractAddress: `0x${string}`
  chainListingId: BaseUnits
}

export interface ListingView {
  listingId: ListingId
  sellerKind: HolderKind
  sellerId: string
  couponTypeId: CouponTypeId
  unitPrice: BaseUnits
  quantity: number
  totalPrice?: BaseUnits
  status: ListingStatus
  createdAt?: string
  /** ผู้ขายเท่านั้นที่เห็นช่องนี้ */
  couponCodeIds?: CouponCodeId[]
  chain: ListingChainView | null
}

export interface ListingAccepted {
  listingId: ListingId
  couponTypeId: CouponTypeId
  unitPrice: BaseUnits
  quantity: number
  totalPrice: BaseUnits
  status: 'PENDING'
  operationId: OperationId
  stepCount: 3
}

export interface OperationStepView {
  index: number
  name: ListingStepName
  status: StepStatus
  txHash: string | null
  nonce: number | null
}

export interface OperationView {
  operationId: OperationId
  kind: 'LISTING_CREATE'
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
  | 'DUPLICATE_CODE'
  | 'NOT_CODE_HOLDER'
  | 'CODE_NOT_HELD'
  | 'CODE_EXPIRED'
  | 'CODE_TYPE_MISMATCH'
  | 'CODE_ALREADY_LISTED'
  | 'LISTING_NOT_FOUND'
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
  | { outcome: 'created'; listingId: ListingId; operationId: OperationId; totalPrice: BaseUnits }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'conflict'; code: Extract<ErrorCode,
      'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS' | 'CODE_ALREADY_LISTED'> }
  | { outcome: 'rejected'; code: Extract<ErrorCode,
      'NOT_CODE_HOLDER' | 'CODE_NOT_HELD' | 'CODE_EXPIRED' | 'CODE_TYPE_MISMATCH'>
      message: string }
