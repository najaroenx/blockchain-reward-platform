/**
 * FEAT-12 · THB Deposit & Mint · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type CustomerId = `cus_${string}`
export type DepositId = `dep_${string}`
export type OperationId = `op_${string}`
export type WebhookId = `wh_${string}`

// ====================================================== สองหน่วยของเงิน
/**
 * หน่วยเล็กสุดของเงินบาทจริง · 1 บาท = 100 สตางค์
 * เก็บเป็น string บน wire เหมือนจำนวนเงินทุกตัว
 */
export type Satang = string & { readonly __brand: 'Satang' }

/** หน่วยเล็กสุดบน chain · 1 บาท = 10^18 */
export type BaseUnits = string & { readonly __brand: 'BaseUnits' }

/**
 * ตัวคูณระหว่างสองหน่วย · คงที่ ไม่เคยเปลี่ยน
 *   1 สตางค์ = 10^16 base units
 *   1 บาท    = 100 สตางค์ = 10^18 base units
 *
 * รอยต่อนี้คือที่ที่บั๊กผิดหลักสิบยกกำลังมักเกิด
 * จึงไม่ใช่เลขที่พิมพ์ซ้ำในหลายที่ · มีที่เดียวและ export ออกไป
 * f_satang_to_base ในฐานข้อมูลใช้ตัวคูณเดียวกัน และ trigger ตรวจทุกแถว
 */
export const SATANG_TO_BASE = 10_000_000_000_000_000n  // 10^16
export const BAHT_TO_SATANG = 100n

export function toSatang(v: string | bigint): Satang {
  const s = typeof v === 'bigint' ? v.toString() : v
  if (!/^[1-9][0-9]*$/.test(s)) throw new RangeError(`ไม่ใช่สตางค์ที่ถูกต้อง: ${s}`)
  return s as Satang
}

export function toBaseUnits(v: string | bigint): BaseUnits {
  const s = typeof v === 'bigint' ? v.toString() : v
  if (!/^[0-9]+$/.test(s)) throw new RangeError(`ไม่ใช่ base units: ${s}`)
  return s as BaseUnits
}

/** สตางค์ → base units · ตรงกับ f_satang_to_base */
export function satangToBase(s: Satang): BaseUnits {
  return toBaseUnits(BigInt(s) * SATANG_TO_BASE)
}

/**
 * base units → สตางค์ · หารลงตัวเท่านั้น
 *
 * ถ้าหารไม่ลงตัว แปลว่าตัวเลขนั้นไม่ได้มาจากการฝากเงินบาท
 * ซึ่งเป็นเรื่องผิดปกติที่ต้องรู้ ไม่ใช่เรื่องที่ควรปัดเศษแล้วเดินต่อ
 */
export function baseToSatang(b: BaseUnits): Satang {
  const v = BigInt(b)
  if (v % SATANG_TO_BASE !== 0n)
    throw new RangeError(`${b} แปลงกลับเป็นสตางค์ไม่ลงตัว · ไม่ได้มาจากการฝากเงินบาท`)
  return toSatang(v / SATANG_TO_BASE)
}

/** ช่วยอ่าน · 100.50 บาท → "10050" สตางค์ */
export function bahtToSatang(baht: number): Satang {
  const cents = Math.round(baht * 100)
  if (!Number.isFinite(baht) || Math.abs(cents - baht * 100) > 1e-6)
    throw new RangeError(`${baht} บาท มีทศนิยมเกินสองตำแหน่ง`)
  return toSatang(BigInt(cents))
}

/** แสดงให้คนอ่าน · "10050" → "100.50" */
export function formatBaht(s: Satang): string {
  const v = BigInt(s)
  const whole = v / BAHT_TO_SATANG
  const frac = v % BAHT_TO_SATANG
  return `${whole}.${frac.toString().padStart(2, '0')}`
}

// -------------------------------------------------------------- เพดาน
export const MIN_DEPOSIT_SATANG = 2_000n        //     20 บาท
export const MAX_DEPOSIT_SATANG = 5_000_000n    // 50,000 บาท

export function isAmountInRange(s: Satang): boolean {
  const v = BigInt(s)
  return v >= MIN_DEPOSIT_SATANG && v <= MAX_DEPOSIT_SATANG
}

// ---------------------------------------------------------------- enums
export type HolderKind = 'MERCHANT' | 'CUSTOMER'

export const DEPOSIT_STATUS = [
  'PENDING_PAYMENT', 'CONFIRMED', 'MINTED', 'REVERSED', 'FAILED', 'EXPIRED',
] as const
export type DepositStatus = (typeof DEPOSIT_STATUS)[number]

export type ReversalOutcome = 'BURNED' | 'MANUAL_REVIEW'

export type LedgerAccount = 'CUSTOMER_THB' | 'MERCHANT_THB' | 'PLATFORM_THB' | 'ISSUANCE'
export type AccountKey = `${LedgerAccount}:${string}`

export function accountKey(account: LedgerAccount, id: string): AccountKey {
  return `${account}:${id}`
}

export function ledgerAccountOf(kind: HolderKind): LedgerAccount {
  return kind === 'MERCHANT' ? 'MERCHANT_THB' : 'CUSTOMER_THB'
}

/** บัญชีคู่ของการนำ THB เข้าและออกจากระบบ */
export const ISSUANCE_KEY: AccountKey = 'ISSUANCE:thb'

// ================================================= กฎของการ mint
/**
 * mint ได้เฉพาะจากการฝากที่ยืนยันแล้ว
 * ตรงกับ trg_mint_requires_confirmed_deposit ข้อแรก
 */
export function isMintable(s: DepositStatus): s is 'CONFIRMED' {
  return s === 'CONFIRMED'
}

/** ตีกลับได้เฉพาะการฝากที่ mint ไปแล้ว · ยังไม่ mint ก็ไม่มีอะไรต้องเผา */
export function isReversible(s: DepositStatus): s is 'MINTED' {
  return s === 'MINTED'
}

/**
 * เส้นทางสถานะที่ยอมรับ · ตรงกับ trg_deposit_status_transition
 * ตารางเดียวกันทั้งสองฝั่ง · แก้ที่นี่ต้องแก้ trigger ด้วย
 */
const TRANSITIONS: Readonly<Record<DepositStatus, readonly DepositStatus[]>> = {
  PENDING_PAYMENT: ['CONFIRMED', 'FAILED', 'EXPIRED'],
  CONFIRMED:       ['MINTED'],
  MINTED:          ['REVERSED'],
  REVERSED:        [],
  FAILED:          [],
  EXPIRED:         [],
}

export function canTransition(from: DepositStatus, to: DepositStatus): boolean {
  if (from === to) return true
  return TRANSITIONS[from].includes(to)
}

/**
 * ผลลัพธ์ของการตีกลับ · คำนวณจากยอดที่ใช้ได้ ไม่ใช่เลือกเอง
 *
 * ตรงกับ trg_reversal_outcome_matches_balance ซึ่งปฏิเสธทั้งสองทิศทาง
 *   อ้าง BURNED ตอนยอดไม่พอ        → 23514
 *   อ้าง MANUAL_REVIEW ตอนยอดพอ   → 23514
 *
 * ทำให้ "เลือกทางที่ง่ายกว่า" เป็นไปไม่ได้ทั้งสองทาง
 */
export function reversalOutcomeFor(
  amount: BaseUnits,
  available: BaseUnits,
): ReversalOutcome {
  return BigInt(available) >= BigInt(amount) ? 'BURNED' : 'MANUAL_REVIEW'
}

// ================================================= สมุดบัญชีของการ mint
export interface LedgerLine {
  account: LedgerAccount
  accountId: AccountKey
  amount: bigint
  memo: string
}

/**
 * สองแถวของการ mint · รวมได้ศูนย์
 *   ปลายทาง  +amount
 *   ISSUANCE −amount
 *
 * F4 คือการเขียนแค่แถวแรกโดยไม่มีแถวที่สอง
 */
export function mintLedger(
  amount: BaseUnits,
  to: { account: LedgerAccount; id: string },
): LedgerLine[] {
  const v = BigInt(amount)
  if (v <= 0n) throw new RangeError('ยอด mint ต้องมากกว่าศูนย์')
  return [
    { account: to.account, accountId: accountKey(to.account, to.id),
      amount: v, memo: 'THB เข้าจากการฝาก' },
    { account: 'ISSUANCE', accountId: ISSUANCE_KEY,
      amount: -v, memo: 'คู่บัญชีของการ mint' },
  ]
}

/** สองแถวของการเผาคืน · ทิศทางกลับกันพอดี */
export function burnLedger(
  amount: BaseUnits,
  from: { account: LedgerAccount; id: string },
): LedgerLine[] {
  const v = BigInt(amount)
  if (v <= 0n) throw new RangeError('ยอดเผาต้องมากกว่าศูนย์')
  return [
    { account: from.account, accountId: accountKey(from.account, from.id),
      amount: -v, memo: 'เผาคืนจากการตีกลับ' },
    { account: 'ISSUANCE', accountId: ISSUANCE_KEY,
      amount: v, memo: 'คู่บัญชีของการเผา' },
  ]
}

/** กฎเดียวกับ trg_ledger_balanced */
export function ledgerBalances(lines: readonly LedgerLine[]): boolean {
  return lines.reduce((s, l) => s + l.amount, 0n) === 0n
}

// ======================================================= หนึ่งขั้นเท่านั้น
/**
 * mint = หนึ่ง tx
 *
 * FEAT-08 มีสามขั้น FEAT-09 และ FEAT-10 มีสองขั้น เพราะงานนั้นต้องการจริง
 * การ mint ต้องการ tx เดียว · เติมขั้นให้ดูเข้าชุดกับ pack อื่นคือการทำผิด
 */
export const MINT_STEPS = ['mintTHB'] as const
export type MintStepName = (typeof MINT_STEPS)[number]
export const MINT_STEP_COUNT = MINT_STEPS.length

// ------------------------------------------------------------- API shape
export interface CreateDepositRequest {
  amountSatang: Satang
}

export interface DepositCreated {
  depositId: DepositId
  amountSatang: Satang
  amountBase: BaseUnits
  status: 'PENDING_PAYMENT'
  paymentUrl: string
  expiresAt: string
}

export interface MintView {
  operationId: OperationId
  amountBase: BaseUnits
  txHash: string | null
  mintedBlock: number | null
}

export interface ReversalView {
  amountBase: BaseUnits
  outcome: ReversalOutcome
  note: string | null
  createdAt: string
}

export interface DepositView {
  depositId: DepositId
  amountSatang: Satang
  amountBase: BaseUnits
  status: DepositStatus
  createdAt: string
  confirmedAt: string | null
  mintedAt: string | null
  mint: MintView | null
  reversal: ReversalView | null
}

export interface BalanceView {
  asset: 'THB'
  amount: BaseUnits
  reserved: BaseUnits
  available: BaseUnits
}

export function availableOf(amount: BaseUnits, reserved: BaseUnits): BaseUnits {
  const a = BigInt(amount) - BigInt(reserved)
  return toBaseUnits(a > 0n ? a : 0n)
}

// --------------------------------------------------------- webhook shape
export type PspEventType = 'charge.complete' | 'charge.failed' | 'charge.reverse'

export interface PspEvent {
  id: string
  type: PspEventType
  data: {
    reference: string
    amountSatang: Satang
  }
}

export interface WebhookAck {
  received: boolean
  duplicate: boolean
}

export type ErrorCode =
  | 'IDEMPOTENCY_KEY_REQUIRED'
  | 'IDEMPOTENCY_KEY_REUSED'
  | 'IDEMPOTENCY_KEY_IN_PROGRESS'
  | 'VALIDATION_FAILED'
  | 'AMOUNT_OUT_OF_RANGE'
  | 'DEPOSIT_NOT_FOUND'
  | 'DEPOSIT_NOT_CONFIRMED'
  | 'DEPOSIT_ALREADY_MINTED'
  | 'AMOUNT_MISMATCH'
  | 'SIGNATURE_INVALID'
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

// -------------------------------------------------------- write results
export type DepositResult =
  | { outcome: 'created'; depositId: DepositId; amountBase: BaseUnits }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'rejected'; code: Extract<ErrorCode,
      'AMOUNT_OUT_OF_RANGE' | 'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS'> }

export type WebhookResult =
  | { outcome: 'accepted'; depositId: DepositId | null; action: string }
  | { outcome: 'duplicate' }
  | { outcome: 'badSignature' }

export type MintResult =
  | { outcome: 'queued'; operationId: OperationId }
  | { outcome: 'rejected'; code: Extract<ErrorCode,
      'DEPOSIT_NOT_FOUND' | 'DEPOSIT_NOT_CONFIRMED'
      | 'DEPOSIT_ALREADY_MINTED' | 'AMOUNT_MISMATCH'> }
