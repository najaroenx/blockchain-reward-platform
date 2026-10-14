/**
 * FEAT-04 · Create Point Type · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type PointTypeId = `pt_${string}`
export type OperationId = `op_${string}`
export type Address = `0x${string}`

// ---------------------------------------------------------------- money
/** RFD 14 · จำนวนในหน่วยเล็กสุด ส่งเป็น string เสมอ ห้ามเป็น number */
export type BaseUnits = string & { readonly __brand: 'BaseUnits' }

export function toBaseUnits(v: string | bigint): BaseUnits {
  const s = typeof v === 'bigint' ? v.toString() : v
  if (!/^[0-9]+$/.test(s)) throw new RangeError(`ไม่ใช่ base units: ${s}`)
  return s as BaseUnits
}

/** แปลงเป็นหน่วยที่คนอ่าน · ใช้ได้ที่ชั้นแสดงผลเท่านั้น */
export function formatUnits(v: BaseUnits, decimals: number): string {
  const s = v.padStart(decimals + 1, '0')
  const whole = s.slice(0, s.length - decimals) || '0'
  const frac = decimals ? '.' + s.slice(s.length - decimals).replace(/0+$/, '') : ''
  return frac === '.' ? whole : whole + frac
}

// ---------------------------------------------------------------- enums
export const POINT_TYPE_STATUS = ['REQUESTED', 'LIVE', 'FAILED', 'RETIRED'] as const
export type PointTypeStatus = (typeof POINT_TYPE_STATUS)[number]

export const OPERATION_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW',
] as const
export type OperationStatus = (typeof OPERATION_STATUS)[number]

export const STEP_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED', 'CHAIN_REVERTED', 'ORPHANED',
] as const
export type StepStatus = (typeof STEP_STATUS)[number]

/** ออก point ด้วย point type นี้ได้หรือยัง */
export function canIssue(s: PointTypeStatus): s is 'LIVE' {
  return s === 'LIVE'
}

/** เฉพาะ FINALIZED เท่านั้นที่แปลว่าเสร็จ · CONFIRMED ยังย้อนได้ (RFD 2 D9) */
export function isDone(s: OperationStatus): s is 'FINALIZED' {
  return s === 'FINALIZED'
}

// ------------------------------------------------------------ validation
export const SYMBOL_RE = /^[A-Z][A-Z0-9]{1,10}$/
export const MAX_DECIMALS = 30

export function isValidSymbol(v: string): boolean {
  return SYMBOL_RE.test(v)
}

/**
 * สูตร normalize ชื่อที่ใช้ตรวจความซ้ำ
 * ต้องตรงกับ `lower(btrim(name))` ใน partial unique index เป๊ะ
 * ถ้าสองที่ใช้คนละสูตร จะมีชื่อที่ API ว่าไม่ซ้ำแต่ฐานข้อมูลว่าซ้ำ
 */
export function normalizeName(raw: string): string {
  return raw.trim().toLowerCase()
}

// ------------------------------------------------------------ epoch math
/**
 * RFD 10 · วันหมดอายุของ point ก้อนหนึ่งคำนวณจากค่าคงที่ของ contract
 * ไม่ใช่จากเวลาที่รัน จึง rebuild projection แล้วได้ค่าเดิมเสมอ
 */
export interface EpochParams {
  genesisAt: Date
  epochSeconds: number
  validityEpochs: number
}

/** epoch ที่เวลา t ตกอยู่ · นับจาก 0 */
export function epochOf(p: EpochParams, t: Date): number {
  const delta = Math.floor((t.getTime() - p.genesisAt.getTime()) / 1000)
  if (delta < 0) return 0
  return Math.floor(delta / p.epochSeconds)
}

/** point ที่ได้รับตอน t หมดอายุเมื่อไหร่ */
export function expiryOf(p: EpochParams, receivedAt: Date): Date {
  const e = epochOf(p, receivedAt)
  const endSeconds = (e + p.validityEpochs) * p.epochSeconds
  return new Date(p.genesisAt.getTime() + endSeconds * 1000)
}

// ------------------------------------------------------------- API shape
export interface CreatePointTypeRequest {
  name: string
  symbol: string
  decimals: number
}

export interface PointTypeChainView {
  contractAddress: Address
  genesisAt: string
  epochSeconds: number
  validityEpochs: number
}

export interface PointTypeView {
  pointTypeId: PointTypeId
  name: string
  symbol: string
  decimals: number
  status: PointTypeStatus
  createdAt?: string
  /** null จนกว่า deploy จะ FINALIZED */
  chain: PointTypeChainView | null
}

export interface CreatePointTypeAccepted {
  pointTypeId: PointTypeId
  name: string
  symbol: string
  decimals: number
  status: 'REQUESTED'
  operationId: OperationId
}

export interface OperationStepView {
  index: number
  name: 'createPointToken'
  status: StepStatus
  txHash: string | null
  nonce: number | null
}

export interface OperationView {
  operationId: OperationId
  kind: 'POINT_TYPE_CREATE'
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
  | 'SYMBOL_TAKEN'
  | 'NAME_TAKEN'
  | 'MERCHANT_WALLET_NOT_READY'
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
  'MERCHANT_WALLET_NOT_READY',
  'RATE_LIMITED',
])

export function isRetryable(e: ApiError): boolean {
  return RETRYABLE.has(e.error.code)
}

// ------------------------------------------------------- write path types
export type AdmitResult =
  | { outcome: 'created'; pointTypeId: PointTypeId; operationId: OperationId }
  | { outcome: 'replayed'; status: number; body: unknown }
  | { outcome: 'conflict'; code: Extract<ErrorCode,
      'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS' | 'SYMBOL_TAKEN' | 'NAME_TAKEN'> }
