/**
 * FEAT-09 · Delist · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type CustomerId = `cus_${string}`
export type AdminId = `adm_${string}`
export type CouponTypeId = `ct_${string}`
export type CouponCodeId = `cc_${string}`
export type ListingId = `lst_${string}`
export type OperationId = `op_${string}`

// ---------------------------------------------------------------- money
/** RFD 14 L3 · จำนวนในหน่วยเล็กสุด ส่งเป็น string เสมอ ห้ามเป็น number */
export type BaseUnits = string & { readonly __brand: 'BaseUnits' }

export function toBaseUnits(v: string | bigint): BaseUnits {
  const s = typeof v === 'bigint' ? v.toString() : v
  if (!/^[0-9]+$/.test(s)) throw new RangeError(`ไม่ใช่ base units: ${s}`)
  return s as BaseUnits
}

export function isBaseUnits(v: unknown): v is BaseUnits {
  return typeof v === 'string' && /^[0-9]+$/.test(v)
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

/** มาจาก event บน chain · ตั้งแล้วเปลี่ยนไม่ได้ */
export type CloseReason = 'CANCELLED' | 'SOLD'

// ================================================ กฎของการถอดรายการขาย
/**
 * ถอดได้เฉพาะสถานะเดียว
 *   PENDING   ยังไม่มี chain_listing_id · ยกเลิกอะไรบน chain ไม่ได้
 *   ACTIVE    ถอดได้
 *   SOLD      ขายไปแล้ว
 *   DELISTED  ถอดไปแล้ว
 *   FAILED    ไม่เคยขึ้น chain · ไม่มีอะไรต้องถอด
 */
export function isDelistable(s: ListingStatus): s is 'ACTIVE' {
  return s === 'ACTIVE'
}

/** ปลายทาง · ออกจากสองสถานะนี้ไม่ได้ (trg_listing_status_transition) */
export function isTerminal(s: ListingStatus): s is 'SOLD' | 'DELISTED' | 'FAILED' {
  return s === 'SOLD' || s === 'DELISTED' || s === 'FAILED'
}

/**
 * งานที่ยังกันรายการขายไว้ไม่ให้รับงานใหม่
 * ตรงกับเงื่อนไขของ uq_listing_inflight เป๊ะ — ถ้าแก้ที่นี่ต้องแก้ index ด้วย
 * ORPHANED และ MANUAL_REVIEW ยังกันอยู่ · รายการที่รอคนตรวจไม่รับงานใหม่
 */
export function isInflight(s: OperationStatus): boolean {
  return s !== 'FINALIZED' && s !== 'CHAIN_REVERTED'
}

/** RFD 9 · ปล่อยของที่กันไว้ได้เมื่องานจบแล้วเท่านั้น */
export function canReleaseHold(s: OperationStatus): boolean {
  return s === 'FINALIZED' || s === 'CHAIN_REVERTED'
}

// ====================================================== สองขั้นของการถอด
/**
 * ถอดหนึ่งครั้ง = สอง tx ที่ต้องเรียงกัน
 * สลับลำดับไม่ได้ · เอาคูปองออกจาก escrow ก่อนปิดรายการ
 * จะเปิดช่วงที่หน้า marketplace ยังโฆษณาของที่ไม่อยู่แล้ว
 * trg_step_order_gate บังคับลำดับนี้ที่ฐานข้อมูล
 */
export const DELIST_STEPS = ['cancelListing', 'releaseFromVault'] as const
export type DelistStepName = (typeof DELIST_STEPS)[number]
export const DELIST_STEP_COUNT = DELIST_STEPS.length

/** ลำดับของการลงขาย · ใช้เทียบให้เห็นว่าการถอดคือการเดินกลับ */
export const LISTING_STEPS = ['approveCoupon', 'createListing', 'lockInVault'] as const

// ------------------------------------------------------------- API shape
export interface DelistAccepted {
  listingId: ListingId
  /**
   * ยัง ACTIVE อยู่ตอนรับงาน
   * เปลี่ยนเป็น DELISTED เมื่อ cancelListing FINALIZED บน chain แล้วเท่านั้น
   */
  status: 'ACTIVE'
  operationId: OperationId
  stepCount: 2
}

export interface ListingChainView {
  contractAddress: `0x${string}`
  chainListingId: BaseUnits
  closeReason: CloseReason | null
}

export interface ListingView {
  listingId: ListingId
  sellerKind: HolderKind
  sellerId: string
  couponTypeId: CouponTypeId
  unitPrice: BaseUnits
  quantity: number
  status: ListingStatus
  activeAt: string | null
  closedAt: string | null
  /** ผู้ขายเท่านั้นที่เห็นช่องนี้ */
  couponCodeIds?: CouponCodeId[]
  chain: ListingChainView | null
}

export interface OperationStepView {
  index: number
  name: DelistStepName
  status: StepStatus
  txHash: string | null
  nonce: number | null
}

export interface OperationView {
  operationId: OperationId
  kind: 'LISTING_DELETE'
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
  | 'LISTING_NOT_FOUND'
  | 'LISTING_NOT_ACTIVE'
  | 'LISTING_BUSY'
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
  'LISTING_BUSY',
  'RATE_LIMITED',
])

export function isRetryable(e: ApiError): boolean {
  return RETRYABLE.has(e.error.code)
}

// -------------------------------------------------------------- actor
/**
 * actor_scope มาจาก token ที่ผ่าน auth แล้ว ไม่ใช่จาก body ของ request
 * F5 เกิดเพราะระบบเดิมเอาค่าจากคำขอมาเป็นตัวตัดสินความเป็นเจ้าของ
 */
export type ActorScope =
  | `merchant:${MerchantId}`
  | `customer:${CustomerId}`
  | `admin:${AdminId}`

export function scopeOf(
  actor: { kind: 'MERCHANT'; id: MerchantId }
       | { kind: 'CUSTOMER'; id: CustomerId }
       | { kind: 'ADMIN'; id: AdminId },
): ActorScope {
  switch (actor.kind) {
    case 'MERCHANT': return `merchant:${actor.id}`
    case 'CUSTOMER': return `customer:${actor.id}`
    case 'ADMIN':    return `admin:${actor.id}`
  }
}

// ------------------------------------------------------- write path types
export type DelistResult =
  | { outcome: 'accepted'; listingId: ListingId; operationId: OperationId }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'notFound' }
  | { outcome: 'conflict'; code: Extract<ErrorCode,
      'LISTING_NOT_ACTIVE' | 'LISTING_BUSY'
      | 'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS'> }
