/**
 * FEAT-02 · Customer Register + OTP · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type CustomerId = `cus_${string}`
export type ChallengeId = `ch_${string}`
export type OperationId = `op_${string}`
export type SessionId = `ses_${string}`

// ======================================================= เบอร์โทร
/**
 * รูปเดียวที่เก็บในฐานข้อมูล
 *
 * F7 · ระบบเดิมเขียนทับเบอร์ด้วยค่าจาก body
 * ที่นี่เบอร์ถูก normalize ครั้งเดียวตอนสร้าง challenge
 * แล้วไม่มีใครเปลี่ยนได้อีก
 */
export type PhoneE164 = string & { readonly __brand: 'PhoneE164' }

const E164 = /^\+[1-9][0-9]{7,14}$/

/**
 * ทำให้เบอร์เป็นรูปเดียว · ตรงกับ f_normalize_phone ในฐานข้อมูล
 *
 * ถ้าสองฝั่ง normalize ไม่ตรงกัน คนเดียวจะมีได้สองบัญชี
 * และ UNIQUE ก็กันไม่ได้ เพราะมันกันค่าที่ต่างกันไม่ได้
 * จึงมีเทสต์ที่เทียบทั้งสองฝั่งทุกเคส
 *
 * คืน null เมื่อรูปที่ได้ไม่ผ่าน E.164 · ไม่เดาแล้วผิด
 */
export function normalizePhone(raw: string): PhoneE164 | null {
  if (!raw) return null
  const hasPlus = raw.trim().startsWith('+')
  const d = raw.replace(/[^0-9]/g, '')
  if (d === '') return null

  let out: string
  if (hasPlus) out = '+' + d
  else if (d.startsWith('66') && d.length === 11) out = '+' + d
  else if (d.startsWith('0') && d.length === 10) out = '+66' + d.slice(1)
  else if (d.length === 9) out = '+66' + d
  else out = d   // รูปที่ไม่รู้จัก · จะไม่ผ่าน E164 ข้างล่าง

  return E164.test(out) ? (out as PhoneE164) : null
}

export function isPhoneE164(v: unknown): v is PhoneE164 {
  return typeof v === 'string' && E164.test(v)
}

/** ปิดเบอร์บางส่วนเวลาแสดงผล · +66812345678 → +6681***5678 */
export function maskPhone(p: PhoneE164): string {
  return p.length <= 8 ? p : p.slice(0, 6) + '***' + p.slice(-4)
}

// ---------------------------------------------------------------- enums
export const CUSTOMER_STATUS = ['PENDING_WALLET','ACTIVE','SUSPENDED','CLOSED'] as const
export type CustomerStatus = (typeof CUSTOMER_STATUS)[number]

export const CHALLENGE_STATUS = ['PENDING','VERIFIED','CONSUMED','EXPIRED','LOCKED'] as const
export type ChallengeStatus = (typeof CHALLENGE_STATUS)[number]

export const ATTEMPT_RESULT = ['OK','WRONG_CODE','EXPIRED','LOCKED','ALREADY_USED'] as const
export type AttemptResult = (typeof ATTEMPT_RESULT)[number]

export type WalletStatus = 'REQUESTED' | 'LIVE' | 'FAILED'

/**
 * ผลที่นับเป็น "การเดา" · ตรงกับเงื่อนไขใน f_attempt_count_matches
 *
 * ความแตกต่างนี้สำคัญ · เรียกตอน challenge ล็อกแล้วไม่ใช่การเดา
 * เพราะรหัสไม่ถูกเอามาเทียบเลย · นับเป็นการเดาจะทำให้ attempts
 * เกิน max_attempts แล้ว CHECK พัง
 */
export function countsAsGuess(r: AttemptResult): boolean {
  return r === 'OK' || r === 'WRONG_CODE'
}

/** ใช้สมัครได้ · ตรงกับ trg_customer_phone_from_challenge */
export function isUsableForSignup(s: ChallengeStatus): s is 'VERIFIED' {
  return s === 'VERIFIED'
}

export function isChallengeDone(s: ChallengeStatus): boolean {
  return s === 'CONSUMED' || s === 'EXPIRED' || s === 'LOCKED'
}

/**
 * เส้นทางสถานะของ challenge · ตรงกับ f_challenge_transition
 * แก้ที่นี่ต้องแก้ trigger ด้วย
 */
const TRANSITIONS: Readonly<Record<ChallengeStatus, readonly ChallengeStatus[]>> = {
  PENDING:  ['VERIFIED', 'EXPIRED', 'LOCKED'],
  VERIFIED: ['CONSUMED', 'EXPIRED'],
  CONSUMED: [],
  EXPIRED:  [],
  LOCKED:   [],
}

export function canTransition(from: ChallengeStatus, to: ChallengeStatus): boolean {
  if (from === to) return true
  return TRANSITIONS[from].includes(to)
}

// =================================================== การจำกัด
export const OTP_LENGTH = 6
export const OTP_TTL_SECONDS = 300
export const MAX_ATTEMPTS = 5
export const RESEND_COOLDOWN_SECONDS = 60
export const MAX_SENDS_PER_HOUR = 5
export const PHONE_LOCK_MINUTES = 30

export function attemptsLeft(attempts: number, maxAttempts = MAX_ATTEMPTS): number {
  return Math.max(maxAttempts - attempts, 0)
}

export function isOtpFormat(code: string): boolean {
  return new RegExp(`^[0-9]{${OTP_LENGTH}}$`).test(code)
}

// ------------------------------------------------------------- API shape
export interface RequestOtpRequest {
  phone: string
}

/**
 * F6 · ไม่มีช่องสำหรับ OTP และจะไม่มี
 *
 * ระบบเดิมคืนค่า OTP กลับมาพร้อมคอมเมนต์ // For testing purposes
 * type นี้กันที่ชั้น compile · openapi.yaml กันที่ชั้น contract
 * ฐานข้อมูลกันที่ชั้น storage · สามชั้นเพราะข้อนี้เคยพลาดมาแล้วจริง
 */
export interface OtpChallengeAccepted {
  challengeId: ChallengeId
  expiresAt: string
  attemptsAllowed: number
}

/**
 * F7 · ไม่มีช่องเบอร์โทร และจะไม่มี
 * เบอร์มาจาก challenge ที่ server สร้างไว้เอง
 */
export interface VerifyOtpRequest {
  challengeId: ChallengeId
  code: string
  displayName?: string
}

/** F12 · ยืนยันเสร็จคือเข้าสู่ระบบแล้ว · ไม่ใช่คืน 201 เปล่า */
export interface VerifyOtpResult {
  customerId: CustomerId
  phone: PhoneE164
  customerStatus: CustomerStatus
  isNewCustomer: boolean
  accessToken: string
  expiresAt: string
  operationId: OperationId | null
}

export interface MeView {
  customerId: CustomerId
  phone: PhoneE164
  displayName: string | null
  customerStatus: CustomerStatus
  walletAddress: `0x${string}` | null
}

export type ErrorCode =
  | 'IDEMPOTENCY_KEY_REQUIRED'
  | 'IDEMPOTENCY_KEY_REUSED'
  | 'VALIDATION_FAILED'
  | 'PHONE_INVALID'
  | 'OTP_WRONG'
  | 'OTP_EXPIRED'
  | 'OTP_LOCKED'
  | 'OTP_ALREADY_USED'
  | 'CHALLENGE_NOT_FOUND'
  | 'RATE_LIMITED'
  | 'UNAUTHORIZED'

export interface ApiError {
  error: {
    code: ErrorCode
    message: string
    requestId: string
    attemptsLeft?: number
  }
}

/** ผลจากฐานข้อมูล → error code ของ API */
export function errorCodeFor(r: AttemptResult): ErrorCode | null {
  switch (r) {
    case 'OK':           return null
    case 'WRONG_CODE':   return 'OTP_WRONG'
    case 'EXPIRED':      return 'OTP_EXPIRED'
    case 'LOCKED':       return 'OTP_LOCKED'
    case 'ALREADY_USED': return 'OTP_ALREADY_USED'
  }
}

/**
 * ลองใหม่ได้ไหม
 *
 * OTP_WRONG ลองใหม่ได้ (ยังเหลือครั้ง) · OTP_LOCKED ไม่ได้ ต้องขอใหม่
 * RATE_LIMITED ลองใหม่ได้แต่ต้องรอ
 */
export function isRetryable(c: ErrorCode): boolean {
  return c === 'OTP_WRONG' || c === 'RATE_LIMITED'
}

export function needsNewChallenge(c: ErrorCode): boolean {
  return c === 'OTP_LOCKED' || c === 'OTP_EXPIRED' || c === 'OTP_ALREADY_USED'
}
