/**
 * FEAT-06 · Point Balance · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 *
 * ชุดนี้เป็นฝั่งอ่านล้วน · ไม่มี AdmitResult ไม่มี Idempotency
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type CustomerId = `cus_${string}`
export type PointTypeId = `pt_${string}`
export type BucketId = `bkt_${string}`
export type NoticeId = `en_${string}`

// ---------------------------------------------------------------- money
/** RFD 14 · จำนวนในหน่วยเล็กสุด ส่งเป็น string เสมอ ห้ามเป็น number */
export type BaseUnits = string & { readonly __brand: 'BaseUnits' }

export function toBaseUnits(v: string | bigint): BaseUnits {
  const s = typeof v === 'bigint' ? v.toString() : v
  if (!/^[0-9]+$/.test(s)) throw new RangeError(`ไม่ใช่ base units: ${s}`)
  return s as BaseUnits
}

/** ลบแบบไม่ติดลบ · ยอดที่ใช้ได้ต่ำสุดคือ 0 เสมอ */
export function subClamped(a: BaseUnits, b: BaseUnits): BaseUnits {
  const d = BigInt(a) - BigInt(b)
  return toBaseUnits(d < 0n ? 0n : d)
}

/** แปลงเป็นหน่วยที่คนอ่าน · ใช้ได้ที่ชั้นแสดงผลเท่านั้น */
export function formatUnits(v: BaseUnits, decimals: number): string {
  const s = v.padStart(decimals + 1, '0')
  const whole = s.slice(0, s.length - decimals) || '0'
  const frac = decimals ? '.' + s.slice(s.length - decimals).replace(/0+$/, '') : ''
  return frac === '.' ? whole : whole + frac
}

// ---------------------------------------------------------------- enums
export type HolderKind = 'MERCHANT' | 'CUSTOMER'
export type Channel = 'PUSH' | 'EMAIL' | 'SMS'

/**
 * ระดับการแจ้งเตือนที่อนุญาต · ต้องตรงกับ CHECK ใน migration.sql เป๊ะ
 * ถ้าเพิ่มที่นี่โดยไม่แก้ DB การบันทึกจะล้มตอน insert ไม่ใช่ตอน compile
 */
export const NOTICE_THRESHOLDS = [30, 7, 1] as const
export type ThresholdDays = (typeof NOTICE_THRESHOLDS)[number]

export function isThreshold(n: number): n is ThresholdDays {
  return (NOTICE_THRESHOLDS as readonly number[]).includes(n)
}

// ----------------------------------------------------------------- asOf
/**
 * ทุก query ฝั่งอ่านรับเวลานี้เข้าไป · ไม่มีฟังก์ชันไหนเรียก now() ข้างใน
 * ทำให้คำตอบเป็นฟังก์ชันบริสุทธิ์ของ (ข้อมูล, เวลา) · T19 ตรวจข้อนี้ในฐานข้อมูล
 */
export interface AsOf {
  readonly at: Date
}

export function asOfNow(): AsOf {
  return { at: new Date() }
}

export function asOfPlusDays(base: AsOf, days: number): AsOf {
  return { at: new Date(base.at.getTime() + days * 86_400_000) }
}

// ------------------------------------------------------------ epoch math
export interface EpochParams {
  genesisAt: Date
  epochSeconds: number
  validityEpochs: number
}

export function epochOf(p: EpochParams, t: Date): number {
  const delta = Math.floor((t.getTime() - p.genesisAt.getTime()) / 1000)
  return delta < 0 ? 0 : Math.floor(delta / p.epochSeconds)
}

/** RFD 10 · ขึ้นกับค่าคงที่ของ contract ไม่ขึ้นกับเวลาที่รัน จึง rebuild ได้ */
export function expiryOf(p: EpochParams, receivedAt: Date): Date {
  const end = (epochOf(p, receivedAt) + p.validityEpochs) * p.epochSeconds
  return new Date(p.genesisAt.getTime() + end * 1000)
}

// ------------------------------------------------------------- API shape
export interface BucketView {
  bucketId: BucketId
  amount: BaseUnits
  receivedAt: string
  expiresAt: string
  /** เทียบกับ asOf ที่ส่งมา ไม่ใช่กับเวลาปัจจุบัน */
  expired: boolean
}

/**
 * projection ตามหลัง chain เสมอ · ค่าชุดนี้ไปกับทุก response
 * ถ้าไม่ส่ง ผู้เรียกจะเข้าใจผิดว่ายอดที่เห็นคือยอดล่าสุดบน chain
 */
export interface Freshness {
  asOfBlock: number
  lagBlocks: number
  lagSeconds: number | null
}

export interface BalanceView {
  pointTypeId: PointTypeId
  holderKind: HolderKind
  holderId: string
  decimals: number
  asOf: string
  available: BaseUnits
  reserved: BaseUnits
  unexpiredTotal: BaseUnits
  /** เรียงตามวันหมดอายุ ใกล้ที่สุดก่อน */
  buckets: BucketView[]
  freshness: Freshness
}

export interface ForecastDay {
  expiresOn: string
  amount: BaseUnits
}

export interface ForecastView {
  pointTypeId: PointTypeId
  asOf: string
  horizonDays: number
  totalExpiring: BaseUnits
  days: ForecastDay[]
}

export interface NoticeRequest {
  bucketId: BucketId
  thresholdDays: ThresholdDays
  channel: Channel
}

export interface NoticeView {
  noticeId: NoticeId
  bucketId: BucketId
  thresholdDays: ThresholdDays
  channel: Channel
  notifiedAt: string
}

export type ErrorCode =
  | 'VALIDATION_FAILED'
  | 'POINT_TYPE_NOT_FOUND'
  | 'BUCKET_NOT_FOUND'
  | 'BUCKET_ALREADY_EXPIRED'
  | 'NOTICE_ALREADY_SENT'
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

/** NOTICE_ALREADY_SENT ไม่ใช่ error ที่ต้องแก้ · แปลว่า job เคยทำไปแล้ว */
export function isBenignConflict(e: ApiError): boolean {
  return e.error.code === 'NOTICE_ALREADY_SENT'
}
