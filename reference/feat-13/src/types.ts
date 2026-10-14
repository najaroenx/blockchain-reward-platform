/**
 * FEAT-13 · Operation Status + Webhook · shared types
 * ตรงกับ api/openapi.yaml และ db/schema.prisma
 */

// ------------------------------------------------------------ domain id
export type MerchantId = `mch_${string}`
export type OperationId = `op_${string}`
export type EndpointId = `ep_${string}`
export type DeliveryId = `wd_${string}`

// ---------------------------------------------------------------- enums
export const OPERATION_KIND = [
  'MERCHANT_PROVISION', 'POINT_TYPE_CREATE', 'POINT_TRANSFER',
  'COUPON_TYPE_CREATE', 'COUPON_ISSUE', 'COUPON_REDEEM',
  'LISTING_CREATE', 'LISTING_DELETE', 'LISTING_BUY', 'THB_MINT',
] as const
export type OperationKind = (typeof OPERATION_KIND)[number]

export const OPERATION_STATUS = [
  'PENDING', 'SUBMITTED', 'CONFIRMED', 'FINALIZED',
  'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW',
] as const
export type OperationStatus = (typeof OPERATION_STATUS)[number]

export type StepStatus =
  'PENDING' | 'SUBMITTED' | 'CONFIRMED' | 'FINALIZED' | 'CHAIN_REVERTED' | 'ORPHANED'

export const DELIVERY_STATUS = ['PENDING', 'IN_FLIGHT', 'SENT', 'DEAD'] as const
export type DeliveryStatus = (typeof DELIVERY_STATUS)[number]

export type EndpointStatus = 'ACTIVE' | 'PAUSED' | 'DISABLED'
export type ActorType = 'SYSTEM' | 'MERCHANT_ADMIN' | 'CUSTOMER' | 'PLATFORM_ADMIN'

// ============================================ เส้นทางสถานะของ operation
/**
 * ตารางเดียวกับ f_operation_status_transition ในฐานข้อมูล
 * แก้ที่นี่ต้องแก้ trigger ด้วย · มิฉะนั้นสองฝั่งจะไม่ตรงกัน
 * และความไม่ตรงนั้นจะโผล่มาเป็น 23514 ที่ไม่มีใครอธิบายได้
 */
const TRANSITIONS: Readonly<Record<OperationStatus, readonly OperationStatus[]>> = {
  PENDING:        ['SUBMITTED', 'MANUAL_REVIEW'],
  SUBMITTED:      ['CONFIRMED', 'CHAIN_REVERTED', 'ORPHANED', 'MANUAL_REVIEW'],
  CONFIRMED:      ['FINALIZED', 'ORPHANED', 'MANUAL_REVIEW'],
  // reorg · tx หลุดจาก chain แล้วถูกยิงใหม่
  ORPHANED:       ['SUBMITTED', 'MANUAL_REVIEW'],
  MANUAL_REVIEW:  ['SUBMITTED', 'CHAIN_REVERTED', 'FINALIZED'],
  FINALIZED:      [],
  CHAIN_REVERTED: [],
}

export function canTransition(from: OperationStatus, to: OperationStatus): boolean {
  if (from === to) return true
  return TRANSITIONS[from].includes(to)
}

/** จบแล้ว · client เลิก poll ได้ */
export function isTerminal(s: OperationStatus): s is 'FINALIZED' | 'CHAIN_REVERTED' {
  return s === 'FINALIZED' || s === 'CHAIN_REVERTED'
}

/**
 * status ไม่ monotonic และนี่คือหลักฐาน
 *
 * ถ้าเรียง status ตามความ "ก้าวหน้า" แล้วบังคับว่าต้องเพิ่มขึ้น
 * reorg จะทำให้กฎนั้นพัง · ฟังก์ชันนี้มีไว้ให้ test ยืนยันข้อนั้น
 * และให้คนที่อ่านโค้ดเห็นว่ามันเป็นเรื่องที่คิดแล้ว ไม่ใช่เรื่องที่ลืม
 */
export function isBackwardLooking(from: OperationStatus, to: OperationStatus): boolean {
  const rank: Record<OperationStatus, number> = {
    PENDING: 0, SUBMITTED: 1, CONFIRMED: 2, FINALIZED: 3,
    ORPHANED: 1, MANUAL_REVIEW: 1, CHAIN_REVERTED: 3,
  }
  return canTransition(from, to) && rank[to] < rank[from]
}

/**
 * ควร poll ถี่แค่ไหน · หน่วยวินาที
 * null = จบแล้ว เลิก poll
 *
 * MANUAL_REVIEW ได้ 300 เพราะรอคน · poll ถี่ไม่ช่วยอะไร
 * มีแต่ทำให้ rate limit หมดเร็ว
 */
export function retryAfterFor(s: OperationStatus): number | null {
  if (isTerminal(s)) return null
  switch (s) {
    case 'PENDING':       return 2
    case 'SUBMITTED':     return 5
    case 'CONFIRMED':     return 15
    case 'ORPHANED':      return 10
    case 'MANUAL_REVIEW': return 300
  }
}

// ============================================ ประวัติที่ต้องครบและต่อเนื่อง
export interface OperationEventView {
  seq: number
  fromStatus: OperationStatus | null
  toStatus: OperationStatus
  actor: ActorType
  txHash: string | null
  createdAt: string
}

/**
 * ตรวจว่าชุด event ที่ได้มาครบและต่อเนื่อง
 *
 * ฐานข้อมูลบังคับข้อนี้อยู่แล้ว (trg_opevent_chain_intact) แต่ client
 * ที่ประกอบจากหลายคำตอบหรือเก็บ cache ไว้ ควรตรวจเองอีกชั้น
 * ถ้าข้อนี้ไม่ผ่าน แปลว่ามีบั๊กที่ฝั่งเรา ไม่ใช่ที่ client
 */
export function eventsAreIntact(events: readonly OperationEventView[]): boolean {
  if (events.length === 0) return false
  const first = events[0]
  if (!first || first.seq !== 1 || first.fromStatus !== null) return false

  for (let i = 1; i < events.length; i++) {
    const prev = events[i - 1]
    const cur = events[i]
    if (!prev || !cur) return false
    if (cur.seq !== prev.seq + 1) return false
    if (cur.fromStatus !== prev.toStatus) return false
    if (cur.fromStatus === null) return false
  }
  return true
}

/** สถานะปัจจุบันอ่านจาก event แถวสุดท้าย ไม่ใช่จากช่องแยก */
export function statusFromEvents(
  events: readonly OperationEventView[],
): OperationStatus | null {
  const last = events[events.length - 1]
  return last ? last.toStatus : null
}

/** เกิด reorg กี่ครั้งในประวัตินี้ · นับจาก event ที่ไปสู่ ORPHANED */
export function reorgCount(events: readonly OperationEventView[]): number {
  return events.filter((e) => e.toStatus === 'ORPHANED').length
}

// ======================================================= การส่ง webhook
/**
 * เวลาหน่วงแบบทวีคูณ · หน่วยวินาที
 * ตรงกับ f_backoff ในฐานข้อมูล · ครั้งที่ 1 รอ 1 นาที ครั้งที่ 6 รอ 32 นาที
 * เพดาน 60 นาที
 */
export function backoffSeconds(attempt: number): number {
  const minutes = Math.min(Math.pow(2, Math.max(attempt - 1, 0)), 60)
  return minutes * 60
}

/**
 * delivery ที่จบแล้ว · ไม่บล็อกลำดับถัดไป และแก้ไม่ได้
 * ตรงกับเงื่อนไขใน trg_delivery_order_gate และ trg_delivery_terminal_immutable
 */
export function isDeliveryDone(s: DeliveryStatus): s is 'SENT' | 'DEAD' {
  return s === 'SENT' || s === 'DEAD'
}

/** ลองครบแล้วหรือยัง */
export function isExhausted(attempt: number, maxAttempts: number): boolean {
  return attempt >= maxAttempts
}

export interface DeliveryAttemptView {
  attempt: number
  startedAt: string
  finishedAt: string
  responseStatus: number | null
  responseBody: string | null
  errorNote: string | null
}

/**
 * ยิงครั้งนั้นถือว่าสำเร็จไหม · 2xx เท่านั้น
 * 3xx ไม่นับ · redirect ของ webhook มักหมายถึงตั้งค่าผิด
 */
export function attemptSucceeded(a: DeliveryAttemptView): boolean {
  return a.responseStatus !== null && a.responseStatus >= 200 && a.responseStatus < 300
}

/**
 * ck_attempt_outcome ในฐานข้อมูล · ต้องมีอย่างใดอย่างหนึ่ง ไม่ใช่ทั้งสอง
 * ยิงแล้วไม่ได้คำตอบและไม่มีข้อผิดพลาด เป็นไปไม่ได้
 */
export function attemptIsWellFormed(a: DeliveryAttemptView): boolean {
  const hasStatus = a.responseStatus !== null
  const hasError = a.errorNote !== null
  return hasStatus !== hasError
}

// ------------------------------------------------------------- API shape
export interface OperationStepView {
  index: number
  name: string
  status: StepStatus
  txHash: string | null
}

export interface OperationSummary {
  operationId: OperationId
  kind: OperationKind
  status: OperationStatus
  eventSeq: number
  createdAt: string
}

export interface OperationView extends OperationSummary {
  finalizedAt: string | null
  terminal: boolean
  errorNote?: string | null
  steps: OperationStepView[]
  events: OperationEventView[]
}

export interface CreateEndpointRequest {
  url: string
  eventTypes: string[]
  maxAttempts?: number
}

export interface EndpointView {
  endpointId: EndpointId
  url: string
  eventTypes: string[]
  status: EndpointStatus
  maxAttempts: number
  createdAt: string
}

/** secret แสดงครั้งเดียวตอนสร้าง · อ่านไม่ได้อีก */
export interface EndpointCreated extends EndpointView {
  secret: string
}

export interface DeliveryView {
  deliveryId: DeliveryId
  operationId: OperationId
  eventSeq: number
  deliverySeq: number
  eventType: string
  status: DeliveryStatus
  attempt: number
  nextAttemptAt: string
  sentAt: string | null
  deadAt: string | null
  attempts: DeliveryAttemptView[]
}

/** สิ่งที่เราส่งไปที่ url ของร้าน */
export interface WebhookBody {
  eventType: string
  operationId: OperationId
  eventSeq: number
  status: OperationStatus
  signedAt: string
  data?: Record<string, unknown>
}

// --------------------------------------------------------- url ของร้าน
/**
 * https เท่านั้น · ck_https_only ในฐานข้อมูลบังคับอีกชั้น
 * ลายเซ็นกัน tamper ได้ แต่ไม่กันการอ่าน
 */
export function isAllowedEndpointUrl(url: string): boolean {
  let u: URL
  try {
    u = new URL(url)
  } catch {
    return false
  }
  if (u.protocol !== 'https:') return false
  // ยิงเข้าเครือข่ายภายในของตัวเองไม่ได้ · กัน SSRF
  const host = u.hostname.toLowerCase()
  if (host === 'localhost' || host.endsWith('.localhost')) return false
  if (host === '169.254.169.254') return false
  if (/^127\./.test(host) || /^10\./.test(host) || /^192\.168\./.test(host)) return false
  if (/^172\.(1[6-9]|2[0-9]|3[01])\./.test(host)) return false
  if (host === '::1' || host === '[::1]') return false
  return true
}

/**
 * รูปแบบของ secret_ref · ตรงกับ trg_endpoint_no_plain_secret
 * เก็บ reference ไม่เก็บค่าความลับ (L6 analogue)
 */
export function isSecretRef(v: string): boolean {
  return v.length <= 200 && /^kms:\/\/[A-Za-z0-9/_.:+=-]+$/.test(v)
}

export type ErrorCode =
  | 'IDEMPOTENCY_KEY_REQUIRED'
  | 'IDEMPOTENCY_KEY_REUSED'
  | 'VALIDATION_FAILED'
  | 'OPERATION_NOT_FOUND'
  | 'ENDPOINT_NOT_FOUND'
  | 'DELIVERY_NOT_FOUND'
  | 'DELIVERY_NOT_DEAD'
  | 'URL_NOT_HTTPS'
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
