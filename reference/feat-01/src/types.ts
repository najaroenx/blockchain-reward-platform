/**
 * FEAT-01 · Merchant Onboarding · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type AdminId = `adm_${string}`
export type OperationId = `op_${string}`
export type WalletId = `wal_${string}`

/** address บน chain · 0x + 40 hex · ไม่เคยถือ private key คู่กัน */
export type Address = `0x${string}`

// ----------------------------------------------------------- idempotency
/**
 * scope ของ Idempotency-Key · ตอนสมัครยังไม่มี actor
 * จึงใช้ anon:<sha256(normalized email)> ไม่ใช่ FK ที่ null ได้ (RFD 3 D1)
 */
export type IdemScope =
  | `merchant:${string}`
  | `admin:${string}`
  | `customer:${string}`
  | `anon:${string}`

// ---------------------------------------------------------------- enums
export const MERCHANT_STATUS = ['PENDING', 'ACTIVE', 'SUSPENDED', 'CLOSED'] as const
export type MerchantStatus = (typeof MERCHANT_STATUS)[number]

export const OPERATION_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW',
] as const
export type OperationStatus = (typeof OPERATION_STATUS)[number]

export const STEP_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED', 'CHAIN_REVERTED', 'ORPHANED',
] as const
export type StepStatus = (typeof STEP_STATUS)[number]

/** สถานะเดียวที่แสดงต่อผู้ใช้ได้ว่า "สำเร็จ" · CONFIRMED ยังย้อนได้ (RFD 2 D9) */
export function isDone(s: OperationStatus): s is 'FINALIZED' {
  return s === 'FINALIZED'
}

/** ร้านทำงานที่ต้องใช้ chain ได้หรือยัง */
export function canUseChain(s: MerchantStatus): boolean {
  return s === 'ACTIVE'
}

// --------------------------------------------------------- normalization
/**
 * NFC → trim → lowercase
 * ต้องใช้ตัวนี้ทั้งตอนเก็บ `email_normalized`, ตอนค้นหา และตอนทำ anon scope
 * ถ้าสามที่ใช้คนละสูตร อีเมลเดียวกันจะกลายเป็นคนละคน
 */
export function normalizeEmail(raw: string): string {
  return raw.normalize('NFC').trim().toLowerCase()
}

// ------------------------------------------------------------- API shape
export interface AdminInput {
  email: string
  /** อย่างน้อย 12 ตัวอักษร · hash ด้วย argon2id ไม่ใช่ bcrypt (RFD 8 D7) */
  password: string
  displayName: string
}

export interface CreateMerchantRequest {
  name: string
  admin: AdminInput
}

export interface WalletView {
  address: Address
  /** true เมื่อ provision บน chain FINALIZED แล้ว */
  ready?: boolean
}

export interface CreateMerchantResponse {
  merchantId: MerchantId
  name: string
  status: 'PENDING'
  createdAt: string
  admin: { adminId: AdminId; email: string }
  wallet: WalletView
  provisioning: { operationId: OperationId; status: 'PENDING' }
}

export interface MerchantView {
  merchantId: MerchantId
  name: string
  status: MerchantStatus
  createdAt: string
  activatedAt: string | null
  wallet?: WalletView
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
  kind: 'MERCHANT_PROVISION'
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
  | 'EMAIL_TAKEN'
  | 'MERCHANT_NOT_FOUND'
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
  'RATE_LIMITED',
])

export function isRetryable(e: ApiError): boolean {
  return RETRYABLE.has(e.error.code)
}

// ------------------------------------------------------------- KMS shape
/**
 * สิ่งเดียวที่ระบบได้จาก KMS คือ address กับ key_ref
 * ไม่มีเมธอดที่คืน private key ออกมา และห้ามเพิ่ม (RFD 4 L6)
 */
export interface KmsKey {
  address: Address
  keyRef: string
}

export interface Kms {
  createKey(label: string): Promise<KmsKey>
  sign(keyRef: string, payload: Buffer): Promise<Buffer>
}

// ------------------------------------------------------- write path types
export type AdmitResult =
  | { outcome: 'created'; merchantId: MerchantId; operationId: OperationId }
  | { outcome: 'replayed'; status: number; body: unknown }
  | {
      outcome: 'conflict'
      code: Extract<ErrorCode, 'IDEMPOTENCY_KEY_REUSED' | 'IDEMPOTENCY_KEY_IN_PROGRESS'>
    }
