/**
 * FEAT-07 · Create Coupon Type + Issue Codes · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */
import { createHash, randomBytes } from 'node:crypto'

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type CouponTypeId = `ct_${string}`
export type CouponCodeId = `cc_${string}`
export type BatchId = `ib_${string}`
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

// ---------------------------------------------------------------- enums
export const COUPON_TYPE_STATUS = ['REQUESTED', 'LIVE', 'FAILED', 'RETIRED'] as const
export type CouponTypeStatus = (typeof COUPON_TYPE_STATUS)[number]

export const COUPON_CODE_STATE = ['ISSUED', 'HELD', 'REDEEMED', 'EXPIRED', 'VOIDED'] as const
export type CouponCodeState = (typeof COUPON_CODE_STATE)[number]

export const OPERATION_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW',
] as const
export type OperationStatus = (typeof OPERATION_STATUS)[number]

export type StepStatus =
  'PENDING' | 'SUBMITTED' | 'CONFIRMED' | 'FINALIZED' | 'CHAIN_REVERTED' | 'ORPHANED'

export type HolderKind = 'MERCHANT' | 'CUSTOMER'

/** ออกรหัสเพิ่มได้หรือยัง */
export function canIssue(s: CouponTypeStatus): s is 'LIVE' {
  return s === 'LIVE'
}

/** ใบที่ยกเลิกแล้วไม่นับในโควตา · ตรงกับเงื่อนไขใน trg_issue_within_supply */
export function countsAgainstSupply(s: CouponCodeState): boolean {
  return s !== 'VOIDED'
}

// ====================================================== รหัสคูปอง
/**
 * Crockford base32 · ตัด I L O U ออกเพื่อไม่ให้อ่านสับสนกับ 1 0
 * 12 ตัวอักษร = 60 บิตของ entropy ต่อหนึ่งรหัส
 */
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
export const CODE_RE = /^[0-9A-HJ-NP-TV-Z]{4}-[0-9A-HJ-NP-TV-Z]{4}-[0-9A-HJ-NP-TV-Z]{4}$/

export function isValidCode(v: string): boolean {
  return CODE_RE.test(v)
}

/**
 * สร้างรหัสจาก CSPRNG · ใช้ rejection sampling เพื่อไม่ให้ตัวอักษรบางตัว
 * มีโอกาสออกมากกว่าตัวอื่น (256 หารด้วย 32 ลงตัว แต่เขียนให้ชัดไว้)
 */
export function generateCode(): string {
  const chars: string[] = []
  while (chars.length < 12) {
    for (const b of randomBytes(24)) {
      if (b >= 256 - (256 % ALPHABET.length)) continue
      chars.push(ALPHABET[b % ALPHABET.length]!)
      if (chars.length === 12) break
    }
  }
  return `${chars.slice(0, 4).join('')}-${chars.slice(4, 8).join('')}-${chars.slice(8).join('')}`
}

/** ใช้ค้นหาตอนลูกค้ายื่นรหัสมา · normalize ให้เป็นตัวใหญ่ก่อนเสมอ */
export function codeHashOf(plaintext: string): Buffer {
  return createHash('sha256').update(plaintext.trim().toUpperCase()).digest()
}

/**
 * ค่าที่ส่งขึ้น chain · **เป็น hash ของ id ไม่ใช่ของ plaintext** (RFD 11 §3.3)
 *
 * indexer และ projector ไม่เคยเห็น plaintext เลย ถ้า codeRef มาจาก plaintext
 * พวกมันจะจับคู่ event กลับมาหาแถวในฐานข้อมูลไม่ได้
 *
 * trigger `trg_code_ref_derived` บังคับข้อนี้ที่ฐานข้อมูล
 * ฟังก์ชันนี้ต้องให้ผลตรงกับ `sha256(convert_to(id,'UTF8'))` ใน SQL เป๊ะ
 */
export function codeRefOf(id: CouponCodeId): Buffer {
  return createHash('sha256').update(id, 'utf8').digest()
}

// ------------------------------------------------------------- batching
/** หนึ่ง tx mint ได้ไม่เกินเท่านี้ · เกินกว่านี้ gas เกิน block limit */
export const MAX_MINT_PER_STEP = 500
/** หนึ่งคำขอออกได้ไม่เกินเท่านี้ */
export const MAX_ISSUE_PER_REQUEST = 10000

export function stepCountFor(quantity: number): number {
  return Math.ceil(quantity / MAX_MINT_PER_STEP)
}

export function chunkSizes(quantity: number): number[] {
  const out: number[] = []
  let left = quantity
  while (left > 0) {
    const take = Math.min(left, MAX_MINT_PER_STEP)
    out.push(take)
    left -= take
  }
  return out
}

// ------------------------------------------------------------- API shape
export interface CreateCouponTypeRequest {
  name: string
  faceValue: BaseUnits
  totalSupply: number
  expiresAt: string
}

export interface CouponTypeChainView {
  contractAddress: `0x${string}`
  chainTypeId: BaseUnits
}

export interface CouponTypeView {
  couponTypeId: CouponTypeId
  name: string
  faceValue: BaseUnits
  totalSupply: number
  issuedCount?: number
  remainingSupply?: number
  status: CouponTypeStatus
  expiresAt: string
  chain: CouponTypeChainView | null
}

export interface CouponTypeAccepted {
  couponTypeId: CouponTypeId
  name: string
  faceValue: BaseUnits
  totalSupply: number
  status: 'REQUESTED'
  expiresAt: string
  operationId: OperationId
}

export interface IssueRequest {
  quantity: number
}

/** plaintext ของรหัส · ค่านี้ออกจากระบบครั้งเดียวเท่านั้น */
export interface IssuedCode {
  couponCodeId: CouponCodeId
  code: string
}

export interface IssueAccepted {
  batchId: BatchId
  couponTypeId: CouponTypeId
  operationId: OperationId
  quantity: number
  stepCount: number
  codes: IssuedCode[]
  warning: string
}

export const ISSUE_WARNING = 'รหัสเหล่านี้จะไม่ถูกส่งอีก กรุณาบันทึกทันที'

export interface OperationStepView {
  index: number
  name: string
  mintCount?: number
  status: StepStatus
  txHash: string | null
  nonce: number | null
}

export interface OperationView {
  operationId: OperationId
  kind: 'COUPON_TYPE_CREATE' | 'COUPON_ISSUE'
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
  | 'NAME_TAKEN'
  | 'SUPPLY_EXCEEDED'
  | 'COUPON_TYPE_NOT_LIVE'
  | 'COUPON_TYPE_EXPIRED'
  | 'COUPON_TYPE_NOT_FOUND'
  | 'MERCHANT_WALLET_NOT_READY'
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
  'MERCHANT_WALLET_NOT_READY',
  'RATE_LIMITED',
])

export function isRetryable(e: ApiError): boolean {
  return RETRYABLE.has(e.error.code)
}

// ------------------------------------------------------- write path types
export type CreateTypeResult =
  | { outcome: 'created'; couponTypeId: CouponTypeId; operationId: OperationId }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'conflict'; code: Extract<ErrorCode,
      'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS' | 'NAME_TAKEN'> }

export type IssueResult =
  | { outcome: 'created'; body: IssueAccepted }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'conflict'; code: Extract<ErrorCode,
      'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS'> }
  | { outcome: 'supplyExceeded'; requested: number; remaining: number }
