/**
 * FEAT-03 · Auth · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type AdminId = `adm_${string}`
export type CustomerId = `cus_${string}`
export type SessionId = `ses_${string}`
export type FamilyId = `fam_${string}`

// ---------------------------------------------------------------- enums
export const SUBJECT_KIND = ['MERCHANT_ADMIN', 'CUSTOMER', 'PLATFORM_ADMIN'] as const
export type SubjectKind = (typeof SUBJECT_KIND)[number]

export const REVOKE_REASON = [
  'LOGOUT', 'ROTATED', 'REUSE_DETECTED',
  'PASSWORD_CHANGED', 'ADMIN_REVOKED', 'EXPIRED',
] as const
export type RevokeReason = (typeof REVOKE_REASON)[number]

export type MerchantStatus = 'PENDING' | 'ACTIVE' | 'SUSPENDED' | 'CLOSED'

// ----------------------------------------------------------- token อายุ
/** 15 นาที · สั้นพอที่การเพิกถอนที่ชั้น refresh จะเพียงพอ (RFD 16 §3.4) */
export const ACCESS_TTL_SECONDS = 900
/** 30 วัน */
export const REFRESH_TTL_SECONDS = 60 * 60 * 24 * 30
/** พลาดกี่ครั้งใน 15 นาทีแล้วล็อก */
export const LOCKOUT_THRESHOLD = 5
export const LOCKOUT_WINDOW_SECONDS = 900

// -------------------------------------------------------------- subject
/** ผู้ใช้ที่ล็อกอินอยู่ · มาจาก JWT ไม่ได้ query ฐานข้อมูลทุก request */
export type Subject =
  | { kind: 'MERCHANT_ADMIN'; id: AdminId; merchantId: MerchantId }
  | { kind: 'CUSTOMER'; id: CustomerId }
  | { kind: 'PLATFORM_ADMIN'; id: string }

/**
 * scope ของ Idempotency-Key ที่ได้จากผู้ใช้ที่ล็อกอินแล้ว (RFD 3 D1)
 * ใช้ตัวนี้แทนการประกอบ string เองทุกที่ จะได้ไม่มีสองสูตร
 */
export function scopeOf(s: Subject): string {
  switch (s.kind) {
    case 'MERCHANT_ADMIN':
      return `merchant:${s.merchantId}`
    case 'CUSTOMER':
      return `customer:${s.id}`
    case 'PLATFORM_ADMIN':
      return `admin:${s.id}`
  }
}

// ---------------------------------------------------------------- JWT
/**
 * payload ของ access token
 * **ไม่มี role ไม่มี permission** · ถ้าสิทธิ์เปลี่ยน token ใบเดิมจะถือสิทธิ์เก่า
 * ต่อไปอีก 15 นาที ซึ่งเป็นช่องที่ไม่คุ้มเปิด (RFD 16 D6)
 */
export interface AccessClaims {
  sub: string
  kind: SubjectKind
  /** merchantId · มีเฉพาะ MERCHANT_ADMIN */
  mid?: MerchantId
  /** session id · ใช้โยง access token กลับไปหา session ตอนทำ audit */
  sid: SessionId
  iat: number
  exp: number
  jti: string
}

// ------------------------------------------------------------- API shape
export interface LoginRequest {
  email: string
  password: string
}

export interface SubjectView {
  kind: SubjectKind
  id: string
  merchantId?: MerchantId | null
  merchantStatus?: MerchantStatus | null
}

export interface LoginResponse {
  accessToken: string
  tokenType: 'Bearer'
  expiresIn: number
  subject: SubjectView
}

export interface RefreshResponse {
  accessToken: string
  tokenType: 'Bearer'
  expiresIn: number
}

export interface SessionView {
  sessionId: SessionId
  current: boolean
  createdAt: string
  expiresAt: string
  userAgent?: string | null
}

export type ErrorCode =
  | 'INVALID_CREDENTIALS'
  | 'ACCOUNT_LOCKED'
  | 'ACCOUNT_DISABLED'
  | 'REFRESH_TOKEN_INVALID'
  | 'REFRESH_TOKEN_EXPIRED'
  | 'REFRESH_TOKEN_REVOKED'
  | 'SESSION_COMPROMISED'
  | 'RATE_LIMITED'

export interface ApiError {
  error: {
    code: ErrorCode
    message: string
    requestId: string
    details?: Record<string, unknown>
  }
}

/**
 * ทุก code ที่แปลว่า "ล็อกอินไม่ผ่าน" ต้องตอบข้อความเดียวกัน
 * ไม่งั้น endpoint นี้จะกลายเป็นเครื่องมือไล่หาว่าอีเมลไหนมีในระบบ
 */
export const GENERIC_LOGIN_FAILURE: ApiError['error'] = {
  code: 'INVALID_CREDENTIALS',
  message: 'อีเมลหรือรหัสผ่านไม่ถูกต้อง',
  requestId: '',
}

// ------------------------------------------------------- refresh outcome
/**
 * ผลของการพยายามหมุน refresh token
 * `compromised` ไม่ใช่แค่ error ธรรมดา · มันแปลว่ามีคนถือ token ของผู้ใช้อยู่
 * จึงต้องเพิกถอนทั้ง family ไม่ใช่แค่ปฏิเสธ request นี้
 */
export type RefreshOutcome =
  | { outcome: 'rotated'; sessionId: SessionId; refreshToken: string; accessToken: string }
  | { outcome: 'invalid' }
  | { outcome: 'expired' }
  | { outcome: 'revoked' }
  | { outcome: 'compromised'; familyId: FamilyId; revokedCount: number }

// ------------------------------------------------------------ normalize
/** สูตรเดียวกับ FEAT-01 · ต้องใช้ทั้งตอนเก็บและตอนค้นหา */
export function normalizeEmail(raw: string): string {
  return raw.normalize('NFC').trim().toLowerCase()
}
