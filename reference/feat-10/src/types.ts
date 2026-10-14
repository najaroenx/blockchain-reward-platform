/**
 * FEAT-10 · Buy Coupon · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type CustomerId = `cus_${string}`
export type AdminId = `adm_${string}`
export type CouponTypeId = `ct_${string}`
export type CouponCodeId = `cc_${string}`
export type ListingId = `lst_${string}`
export type PurchaseId = `pur_${string}`
export type OperationId = `op_${string}`

// ---------------------------------------------------------------- money
/**
 * RFD 14 L3 · จำนวนในหน่วยเล็กสุด ส่งเป็น string เสมอ
 *
 * ราคา 80 THB = 80e18 base units · คูณ 500 ใบ = 4e22
 * Number.MAX_SAFE_INTEGER คือ 9.007e15 · ต่างกันเจ็ดลำดับ
 * ตัวเลขฝั่งเงินทุกตัวในไฟล์นี้จึงผ่าน bigint ไม่มีข้อยกเว้น
 */
export type BaseUnits = string & { readonly __brand: 'BaseUnits' }

export function toBaseUnits(v: string | bigint): BaseUnits {
  const s = typeof v === 'bigint' ? v.toString() : v
  if (!/^[0-9]+$/.test(s)) throw new RangeError(`ไม่ใช่ base units: ${s}`)
  return s as BaseUnits
}

export function isBaseUnits(v: unknown): v is BaseUnits {
  return typeof v === 'string' && /^[0-9]+$/.test(v)
}

export const BPS_DENOM = 10000n

// ======================================================= การคิดเงิน
/**
 * ผลลัพธ์ของการคิดเงินหนึ่งครั้ง · ทุกช่องเป็น base units
 * ข้อรับประกัน: fee + net === total เสมอ · ตรวจซ้ำที่ฐานข้อมูลอีกชั้น
 */
export interface Money {
  totalPrice: BaseUnits
  feeBps: number
  feeAmount: BaseUnits
  netToSeller: BaseUnits
}

/**
 * คิดเงินของการซื้อหนึ่งครั้ง
 *
 * ปัดลงเสมอ และ **เศษที่ปัดตกเป็นของผู้ขาย ไม่ใช่ของ platform**
 * เพราะ net คำนวณจาก total ลบ fee ไม่ใช่คำนวณแยกกันสองเส้น
 * ถ้าคำนวณแยกกัน ผลรวมจะขาดได้หนึ่งหน่วย และหน่วยนั้นจะหายไปจากระบบ
 * ซึ่ง trg_ledger_balanced จะไม่ยอม commit ให้
 *
 * ตรงกับ f_purchase_math ในฐานข้อมูลตัวต่อตัว
 */
export function priceOf(
  unitPrice: BaseUnits,
  quantity: number,
  feeBps: number,
): Money {
  if (!Number.isInteger(quantity) || quantity < 1)
    throw new RangeError(`quantity ต้องเป็นจำนวนเต็มบวก · ได้ ${quantity}`)
  if (!Number.isInteger(feeBps) || feeBps < 0 || feeBps > 10000)
    throw new RangeError(`feeBps ต้องอยู่ระหว่าง 0 ถึง 10000 · ได้ ${feeBps}`)

  const total = BigInt(unitPrice) * BigInt(quantity)
  if (total <= 0n) throw new RangeError('ยอดรวมต้องมากกว่าศูนย์')

  // bigint หารแบบปัดลงให้เองอยู่แล้ว · ตรงกับ div() ของ Postgres
  const fee = (total * BigInt(feeBps)) / BPS_DENOM
  const net = total - fee

  return {
    totalPrice: toBaseUnits(total),
    feeBps,
    feeAmount: toBaseUnits(fee),
    netToSeller: toBaseUnits(net),
  }
}

/** ตรวจว่าชุดตัวเลขสมดุล · ใช้ก่อนเขียนลงฐานข้อมูลและใน test */
export function moneyBalances(m: Money): boolean {
  return BigInt(m.feeAmount) + BigInt(m.netToSeller) === BigInt(m.totalPrice)
}

// ======================================================= สมุดบัญชี
export type LedgerAccount =
  | 'CUSTOMER_THB'
  | 'MERCHANT_THB'
  | 'PLATFORM_THB'
  | 'ISSUANCE'

/**
 * คีย์ของบัญชี · เขียนเป็น '<ACCOUNT>:<id>'
 * รูปนี้ตรงกับ reservation.subject_id ของ THB_BALANCE แบบตัวต่อตัว
 * trg_thb_reservation_balance แยกส่วนด้วย split_part แล้ว cast
 */
export type AccountKey = `${LedgerAccount}:${string}`

export function accountKey(account: LedgerAccount, id: string): AccountKey {
  return `${account}:${id}`
}

export interface LedgerLine {
  account: LedgerAccount
  accountId: AccountKey
  /** ลบคือออก บวกคือเข้า · ศูนย์ไม่ยอมรับ */
  amount: bigint
  memo: string
}

/**
 * สามแถวของการซื้อหนึ่งครั้ง · รวมได้ศูนย์
 *
 *   คนซื้อ   −total
 *   ผู้ขาย   +net
 *   platform +fee
 *
 * F8 คือการที่ชุดนี้ไม่เคยถูกเขียนเลย
 */
export function purchaseLedger(
  m: Money,
  buyer: { account: LedgerAccount; id: string },
  seller: { account: LedgerAccount; id: string },
  platformId: string,
): LedgerLine[] {
  const lines: LedgerLine[] = [
    {
      account: buyer.account,
      accountId: accountKey(buyer.account, buyer.id),
      amount: -BigInt(m.totalPrice),
      memo: 'จ่ายค่าคูปอง',
    },
    {
      account: seller.account,
      accountId: accountKey(seller.account, seller.id),
      amount: BigInt(m.netToSeller),
      memo: 'รับเงินสุทธิ',
    },
  ]
  // fee เป็นศูนย์ได้ถ้า bps เป็นศูนย์ · แถวที่ไม่เคลื่อนอะไรต้องไม่มีอยู่
  if (BigInt(m.feeAmount) > 0n) {
    lines.push({
      account: 'PLATFORM_THB',
      accountId: accountKey('PLATFORM_THB', platformId),
      amount: BigInt(m.feeAmount),
      memo: 'ค่าธรรมเนียม',
    })
  }
  return lines
}

/** กฎเดียวกับ trg_ledger_balanced · ตรวจก่อนส่งไปฐานข้อมูล */
export function ledgerBalances(lines: readonly LedgerLine[]): boolean {
  return lines.reduce((s, l) => s + l.amount, 0n) === 0n
}

// ---------------------------------------------------------------- enums
export type HolderKind = 'MERCHANT' | 'CUSTOMER'

export const LISTING_STATUS = ['PENDING', 'ACTIVE', 'SOLD', 'DELISTED', 'FAILED'] as const
export type ListingStatus = (typeof LISTING_STATUS)[number]

export const PURCHASE_STATUS = ['PENDING', 'SETTLED', 'FAILED'] as const
export type PurchaseStatus = (typeof PURCHASE_STATUS)[number]

export const OPERATION_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW',
] as const
export type OperationStatus = (typeof OPERATION_STATUS)[number]

export type StepStatus =
  'PENDING' | 'SUBMITTED' | 'CONFIRMED' | 'FINALIZED' | 'CHAIN_REVERTED' | 'ORPHANED'

/** ซื้อได้เฉพาะ ACTIVE */
export function isBuyable(s: ListingStatus): s is 'ACTIVE' {
  return s === 'ACTIVE'
}

/** ตรงกับเงื่อนไขของ uq_listing_inflight · แก้ที่นี่ต้องแก้ index ด้วย */
export function isInflight(s: OperationStatus): boolean {
  return s !== 'FINALIZED' && s !== 'CHAIN_REVERTED'
}

export function canReleaseHold(s: OperationStatus): boolean {
  return s === 'FINALIZED' || s === 'CHAIN_REVERTED'
}

// ====================================================== สองขั้นของการซื้อ
/**
 * ซื้อหนึ่งครั้ง = สอง tx
 *   1 approveTHB       อนุมัติเท่า totalPrice พอดี ไม่ใช่ไม่จำกัด
 *   2 executePurchase  tx เดียวที่ย้ายทั้งเงินและคูปอง
 *
 * ขั้นที่ 2 เป็น tx เดียวโดยตั้งใจ · แยกเงินกับของเป็นสอง tx
 * จะเกิดสถานะ "จ่ายแล้วแต่ไม่ได้ของ" ที่ต้องมีทางกู้คืน
 * และทางกู้คืนนั้นคือที่ที่ F8 ตายไป — มีฟังก์ชันแต่ไม่มีใครเรียก
 */
export const BUY_STEPS = ['approveTHB', 'executePurchase'] as const
export type BuyStepName = (typeof BUY_STEPS)[number]
export const BUY_STEP_COUNT = BUY_STEPS.length

// ------------------------------------------------------------- API shape
export interface BuyRequest {
  /** ยอดรวมที่หน้าจอแสดงไว้ · ไม่ตรงกับที่ server คิดได้ → PRICE_MISMATCH */
  expectedTotalPrice: BaseUnits
}

export interface PurchaseAccepted {
  purchaseId: PurchaseId
  listingId: ListingId
  totalPrice: BaseUnits
  feeBps: number
  feeAmount: BaseUnits
  netToSeller: BaseUnits
  status: 'PENDING'
  operationId: OperationId
  stepCount: 2
}

export interface PurchaseView {
  purchaseId: PurchaseId
  listingId: ListingId
  buyerKind: HolderKind
  buyerId: string
  sellerKind: HolderKind
  sellerId: string
  unitPrice: BaseUnits
  quantity: number
  totalPrice: BaseUnits
  feeBps: number
  feeAmount: BaseUnits
  netToSeller: BaseUnits
  status: PurchaseStatus
  createdAt: string
  settledAt: string | null
  /** ผู้ซื้อเห็นช่องนี้หลัง SETTLED แล้วเท่านั้น */
  couponCodeIds?: CouponCodeId[]
}

export interface BalanceView {
  asset: 'THB'
  amount: BaseUnits
  reserved: BaseUnits
  available: BaseUnits
}

/** available = amount − reserved · ตรงกับ f_available_thb ในฐานข้อมูล */
export function availableOf(amount: BaseUnits, reserved: BaseUnits): BaseUnits {
  const a = BigInt(amount) - BigInt(reserved)
  return toBaseUnits(a > 0n ? a : 0n)
}

export interface ListingView {
  listingId: ListingId
  sellerKind: HolderKind
  sellerId: string
  couponTypeId: CouponTypeId
  unitPrice: BaseUnits
  quantity: number
  totalPrice: BaseUnits
  status: ListingStatus
}

export interface OperationStepView {
  index: number
  name: BuyStepName
  status: StepStatus
  txHash: string | null
  nonce: number | null
}

export interface OperationView {
  operationId: OperationId
  kind: 'LISTING_BUY'
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
  | 'SELF_PURCHASE'
  | 'INSUFFICIENT_THB'
  | 'PRICE_MISMATCH'
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

/**
 * INSUFFICIENT_THB ไม่อยู่ใน RETRYABLE โดยตั้งใจ
 * ลองใหม่ด้วยเงินเท่าเดิมก็ไม่พอเหมือนเดิม · ต้องเติมเงินก่อน
 * ระบบเดิมแก้ด้วยการเสกเงินให้ (F4) ซึ่งทำให้ปัญหานี้ "หายไป" แบบผิดวิธี
 */
export function needsTopUp(e: ApiError): boolean {
  return e.error.code === 'INSUFFICIENT_THB'
}

// -------------------------------------------------------------- actor
export type ActorScope =
  | `merchant:${MerchantId}`
  | `customer:${CustomerId}`
  | `admin:${AdminId}`

export function ledgerAccountOf(kind: HolderKind): LedgerAccount {
  return kind === 'MERCHANT' ? 'MERCHANT_THB' : 'CUSTOMER_THB'
}

// ------------------------------------------------------- write path types
export type BuyResult =
  | { outcome: 'accepted'; purchaseId: PurchaseId; operationId: OperationId; money: Money }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'notFound' }
  | { outcome: 'conflict'; code: Extract<ErrorCode,
      'LISTING_NOT_ACTIVE' | 'LISTING_BUSY' | 'SELF_PURCHASE'
      | 'INSUFFICIENT_THB' | 'PRICE_MISMATCH'
      | 'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS'> }
