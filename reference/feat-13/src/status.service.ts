/**
 * FEAT-13 · อ่านสถานะงาน และส่ง webhook
 *
 * สิ่งที่ feature นี้ต่างจากชุดก่อน
 *   1 · เป็น feature แรกที่ "อ่าน" เป็นงานหลัก ไม่ใช่ "เขียน"
 *   2 · การเปลี่ยนสถานะทุกครั้งต้องผ่าน advance() ที่เขียน event ให้ด้วย
 *       เขียน UPDATE operation ตรงๆ จะไม่ผ่าน COMMIT
 *   3 · ส่ง webhook ของงานเดียวกันเรียงลำดับ · ฐานข้อมูลบังคับ
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  DeliveryId, DeliveryStatus, EndpointId, OperationEventView,
  OperationId, OperationStatus, OperationView, WebhookBody,
} from './types'
import {
  backoffSeconds, canTransition, eventsAreIntact, isAllowedEndpointUrl,
  isDeliveryDone, isExhausted, isSecretRef, isTerminal, retryAfterFor,
} from './types'
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto'

export class StatusService {
  constructor(private readonly db: PrismaClient) {}

  // =============================================== เปลี่ยนสถานะ
  /**
   * ทางเดียวที่ควรเปลี่ยนสถานะ operation
   *
   * เขียน UPDATE operation ตรงๆ ที่อื่นจะไม่ผ่าน trg_status_has_event
   * ตอน COMMIT · ซึ่งเป็นสิ่งที่ต้องการ · มีทางเดียวแล้วบังคับทางนั้นให้ถูก
   * ง่ายกว่ามีสิบทางแล้วหวังว่าทุกทางจำกฎได้
   *
   * seq คำนวณจาก max ที่มีอยู่ · อยู่ใน transaction เดียวกับการ UPDATE
   * จึงไม่มีช่องให้สองคนได้ seq เดียวกัน (uq_opevent_seq กันอีกชั้น)
   */
  async advance(
    operationId: OperationId,
    to: OperationStatus,
    opts: {
      actor?: 'SYSTEM' | 'MERCHANT_ADMIN' | 'CUSTOMER' | 'PLATFORM_ADMIN'
      txHash?: Buffer
      metadata?: Record<string, unknown>
      errorNote?: string
    } = {},
  ): Promise<{ seq: number; from: OperationStatus; to: OperationStatus }> {
    return this.db.$transaction(async (tx) => {
      const op = await tx.operation.findUnique({ where: { id: operationId } })
      if (!op) throw new Error(`ไม่พบ operation ${operationId}`)

      const from = op.status as OperationStatus
      if (from === to) throw new Error(`operation ${operationId} อยู่สถานะ ${to} อยู่แล้ว`)

      // ตรวจที่โค้ดก่อน เพื่อให้ข้อความอ่านรู้เรื่อง
      // ฐานข้อมูลตรวจซ้ำอยู่แล้ว และนั่นคือชั้นที่กันได้จริง
      if (!canTransition(from, to))
        throw new Error(`เปลี่ยนสถานะจาก ${from} ไป ${to} ไม่ได้`)

      const rows = (await tx.$queryRaw`
        SELECT coalesce(max(seq), 0) + 1 AS next
          FROM operation_event WHERE operation_id = ${operationId}
      `) as { next: number }[]
      const seq = Number(rows[0]?.next ?? 1)

      await tx.operation.update({
        where: { id: operationId },
        data: {
          status: to,
          ...(opts.errorNote !== undefined ? { errorNote: opts.errorNote } : {}),
        },
      })

      await tx.operationEvent.create({
        data: {
          id: 'oev_' + short(),
          operationId,
          seq,
          fromStatus: from,
          toStatus: to,
          actor: opts.actor ?? 'SYSTEM',
          ...(opts.txHash ? { txHash: opts.txHash } : {}),
          metadata: (opts.metadata ?? {}) as Prisma.InputJsonValue,
        },
      })

      // ตั้งคิวส่ง webhook ให้ทุก endpoint ที่สนใจ event ชนิดนี้
      await this.enqueueDeliveries(tx, operationId, seq, to)

      return { seq, from, to }
    })
  }

  // =============================================== อ่านสถานะ
  /**
   * สถานะและประวัติทั้งหมด
   *
   * สถานะที่คืนไปอ่านจาก event แถวสุดท้าย ไม่ใช่จาก operation.status
   * สองค่านี้ต้องตรงกันอยู่แล้ว (trg_status_has_event) แต่การอ่านจาก event
   * ทำให้ API กับสิ่งที่ client ควรเชื่อ เป็นสิ่งเดียวกัน
   */
  async get(operationId: OperationId): Promise<(OperationView & {
    retryAfter: number | null
    etag: string
  }) | null> {
    const op = await this.db.operation.findUnique({
      where: { id: operationId },
      include: {
        steps: { orderBy: { stepIndex: 'asc' } },
        events: { orderBy: { seq: 'asc' } },
      },
    })
    if (!op) return null

    const events: OperationEventView[] = (op.events as {
      seq: number
      fromStatus: string | null
      toStatus: string
      actor: string
      txHash: Buffer | null
      createdAt: Date
    }[]).map((e) => ({
      seq: e.seq,
      fromStatus: e.fromStatus as OperationStatus | null,
      toStatus: e.toStatus as OperationStatus,
      actor: e.actor as never,
      txHash: e.txHash ? '0x' + e.txHash.toString('hex') : null,
      createdAt: e.createdAt.toISOString(),
    }))

    // ควรจริงเสมอจาก trg_opevent_chain_intact
    // เช็คไว้เพราะถ้าไม่จริง แปลว่าบั๊กอยู่ฝั่งเรา และต้องรู้ทันที
    if (!eventsAreIntact(events))
      throw new Error(`ประวัติของ ${operationId} ขาดช่วงหรือไม่ต่อเนื่อง`)

    const last = events[events.length - 1]
    if (!last) throw new Error(`operation ${operationId} ไม่มี event เลย`)
    const status = last.toStatus

    return {
      operationId: op.id as OperationId,
      kind: op.kind as never,
      status,
      eventSeq: last.seq,
      createdAt: op.createdAt.toISOString(),
      finalizedAt: op.finalizedAt ? op.finalizedAt.toISOString() : null,
      terminal: isTerminal(status),
      errorNote: op.errorNote as string | null,
      steps: (op.steps as {
        stepIndex: number; name: string; status: string; txHash: Buffer | null
      }[]).map((s) => ({
        index: s.stepIndex,
        name: s.name,
        status: s.status as never,
        txHash: s.txHash ? '0x' + s.txHash.toString('hex') : null,
      })),
      events,
      retryAfter: retryAfterFor(status),
      // ETag อิงจาก seq · เปลี่ยนเมื่อมี event ใหม่เท่านั้น
      etag: `"${operationId}-${last.seq}"`,
    }
  }

  // =============================================== ตั้งคิวส่ง
  /**
   * สร้างงานส่งให้ทุก endpoint ที่สนใจ event ชนิดนี้
   *
   * payload ถูกเซ็นตอนนี้ และเก็บทั้ง body และลายเซ็นไว้
   * เพราะ trg_delivery_terminal_immutable ไม่ยอมให้แก้ทีหลัง
   * เซ็นแล้วเปลี่ยนเนื้อหา = ลายเซ็นไม่ตรงกับของที่ส่งจริง
   */
  private async enqueueDeliveries(
    tx: {
      $queryRaw(s: TemplateStringsArray, ...v: unknown[]): Promise<unknown[]>
      webhookDelivery: { create(a: unknown): Promise<unknown> }
    },
    operationId: OperationId,
    eventSeq: number,
    status: OperationStatus,
  ): Promise<void> {
    const eventType = eventTypeOf(status)

    const eps = (await tx.$queryRaw`
      SELECT id, secret_ref FROM webhook_endpoint
       WHERE status = 'ACTIVE' AND ${eventType} = ANY(event_types)
    `) as { id: string; secret_ref: string }[]

    for (const ep of eps) {
      const seqRows = (await tx.$queryRaw`
        SELECT coalesce(max(delivery_seq), 0) + 1 AS next
          FROM webhook_delivery
         WHERE endpoint_id = ${ep.id} AND operation_id = ${operationId}
      `) as { next: number }[]
      const deliverySeq = Number(seqRows[0]?.next ?? 1)

      const signedAt = new Date()
      const body: WebhookBody = {
        eventType,
        operationId,
        eventSeq,
        status,
        signedAt: signedAt.toISOString(),
      }
      // ของจริงดึง secret จาก KMS ด้วย secret_ref
      // ฐานข้อมูลไม่เคยเก็บค่าความลับ (trg_endpoint_no_plain_secret)
      const secret = await this.resolveSecret(ep.secret_ref)

      await tx.webhookDelivery.create({
        data: {
          id: 'wd_' + short(),
          endpointId: ep.id,
          operationId,
          eventSeq,
          deliverySeq,
          eventType,
          payload: body as unknown as Prisma.InputJsonValue,
          signature: signBody(secret, signedAt, JSON.stringify(body)),
          signedAt,
        },
      })
    }
  }

  // =============================================== หยิบงานไปส่ง
  /**
   * หยิบงานที่ถึงเวลา · FOR UPDATE SKIP LOCKED
   *
   * เงื่อนไขในนี้ตรงกับ ix_delivery_due เป๊ะ จึงใช้ index ได้
   * และ trg_delivery_order_gate จะปฏิเสธถ้าลำดับก่อนหน้ายังไม่จบ
   * worker จึงไม่ต้องเรียงเองและเรียงผิดไม่ได้
   */
  async claim(limit = 10): Promise<DeliveryId[]> {
    const rows = (await this.db.$queryRaw`
      WITH due AS (
        SELECT id FROM webhook_delivery
         WHERE status = 'PENDING' AND next_attempt_at <= now()
         ORDER BY next_attempt_at
         FOR UPDATE SKIP LOCKED
         LIMIT ${limit}
      )
      UPDATE webhook_delivery d
         SET status = 'IN_FLIGHT', claimed_at = now()
        FROM due
       WHERE d.id = due.id
      RETURNING d.id
    `) as { id: string }[]
    return rows.map((r) => r.id as DeliveryId)
  }

  /**
   * บันทึกผลการยิงหนึ่งครั้ง
   *
   * attempt ต้องเพิ่มพร้อมกับการสร้างแถว attempt
   * trg_attempt_count_matches ตรวจตอน COMMIT ว่าสองตัวเลขตรงกัน
   * นับเองแล้วเขียนตัวเลขลงไป จะไม่ตรงเมื่อมีใครลืมเขียนแถว
   */
  async recordAttempt(
    deliveryId: DeliveryId,
    result:
      | { responseStatus: number; responseBody: string }
      | { errorNote: string },
    timing: { startedAt: Date; finishedAt: Date },
  ): Promise<{ status: DeliveryStatus; nextAttemptAt: Date | null }> {
    return this.db.$transaction(async (tx) => {
      const d = await tx.webhookDelivery.findUnique({
        where: { id: deliveryId },
        include: { endpoint: true },
      })
      if (!d) throw new Error(`ไม่พบงานส่ง ${deliveryId}`)
      if (isDeliveryDone(d.status as DeliveryStatus))
        throw new Error(`งานส่ง ${deliveryId} จบที่ ${d.status} ไปแล้ว`)

      const attempt = (d.attempt as number) + 1
      await tx.webhookDelivery.update({
        where: { id: deliveryId },
        data: { attempt },
      })
      await tx.webhookDeliveryAttempt.create({
        data: {
          id: 'wa_' + short(),
          deliveryId,
          attempt,
          startedAt: timing.startedAt,
          finishedAt: timing.finishedAt,
          ...('responseStatus' in result
            ? { responseStatus: result.responseStatus, responseBody: result.responseBody }
            : { errorNote: result.errorNote }),
        },
      })

      const ok = 'responseStatus' in result
        && result.responseStatus >= 200 && result.responseStatus < 300

      if (ok) {
        await tx.webhookDelivery.update({
          where: { id: deliveryId },
          data: { status: 'SENT', sentAt: new Date() },
        })
        return { status: 'SENT' as const, nextAttemptAt: null }
      }

      const maxAttempts = (d.endpoint as { maxAttempts: number }).maxAttempts
      if (isExhausted(attempt, maxAttempts)) {
        await tx.webhookDelivery.update({
          where: { id: deliveryId },
          data: { status: 'DEAD', deadAt: new Date() },
        })
        return { status: 'DEAD' as const, nextAttemptAt: null }
      }

      const next = new Date(Date.now() + backoffSeconds(attempt) * 1000)
      await tx.webhookDelivery.update({
        where: { id: deliveryId },
        data: { status: 'PENDING', nextAttemptAt: next, claimedAt: null },
      })
      return { status: 'PENDING' as const, nextAttemptAt: next }
    })
  }

  /**
   * ส่งซ้ำงานที่ DEAD · สร้างแถวใหม่ ไม่ปลุกแถวเดิม
   *
   * แถวเดิมเป็นหลักฐานว่าเราส่งอะไรไปและได้คำตอบอะไร
   * แก้ย้อนหลังได้ก็เลิกเป็นหลักฐาน · trg_delivery_terminal_immutable บังคับ
   */
  async replay(deliveryId: DeliveryId): Promise<DeliveryId> {
    return this.db.$transaction(async (tx) => {
      const old = await tx.webhookDelivery.findUnique({
        where: { id: deliveryId },
        include: { endpoint: true },
      })
      if (!old) throw new Error(`ไม่พบงานส่ง ${deliveryId}`)
      if (old.status !== 'DEAD')
        throw new Error(`งานส่ง ${deliveryId} อยู่สถานะ ${old.status} · ส่งซ้ำได้เฉพาะ DEAD`)

      const seqRows = (await tx.$queryRaw`
        SELECT coalesce(max(delivery_seq), 0) + 1 AS next
          FROM webhook_delivery
         WHERE endpoint_id = ${old.endpointId} AND operation_id = ${old.operationId}
      `) as { next: number }[]
      const deliverySeq = Number(seqRows[0]?.next ?? 1)

      // เซ็นใหม่ด้วยเวลาใหม่ · ร้านปฏิเสธ body เก่าได้ด้วย signedAt
      const signedAt = new Date()
      const body = { ...(old.payload as Record<string, unknown>), signedAt: signedAt.toISOString() }
      const secret = await this.resolveSecret(
        (old.endpoint as { secretRef: string }).secretRef,
      )

      const id = ('wd_' + short()) as DeliveryId
      await tx.webhookDelivery.create({
        data: {
          id,
          endpointId: old.endpointId,
          operationId: old.operationId,
          // event_seq เดิม · ใช้ได้เพราะ uq_delivery_event เป็น partial index
          // ที่ครอบเฉพาะแถวที่ replay_of IS NULL
          eventSeq: old.eventSeq,
          deliverySeq,
          eventType: old.eventType,
          payload: body as Prisma.InputJsonValue,
          signature: signBody(secret, signedAt, JSON.stringify(body)),
          signedAt,
          // ชี้กลับไปที่แถวเดิม · trg_replay_valid ตรวจว่าแถวเดิม DEAD
          // และเป็น endpoint · operation · event เดียวกัน
          replayOf: deliveryId,
        },
      })
      return id
    })
  }

  /** ของจริงเรียก KMS · ที่นี่เป็นที่เดียวที่รู้จักค่าความลับ */
  private async resolveSecret(secretRef: string): Promise<string> {
    if (!isSecretRef(secretRef))
      throw new Error(`secret_ref ไม่ถูกรูป · ${secretRef.slice(0, 40)}`)
    // ตัวแทนในระหว่างที่ยังไม่ต่อ KMS จริง
    return `resolved:${secretRef}`
  }

  /** ตรวจก่อนรับ url ของร้าน · กัน SSRF เข้าเครือข่ายภายใน */
  static validateEndpointUrl(url: string): void {
    if (!isAllowedEndpointUrl(url))
      throw new Error(`url ใช้ไม่ได้ · ต้องเป็น https และไม่ใช่ที่อยู่ภายใน · ${url}`)
  }
}

/**
 * ลายเซ็นของ webhook ที่เราส่งออก
 *
 * ใส่ signedAt ในสิ่งที่เซ็น เพื่อให้ร้านปฏิเสธ body เก่าที่ถูกเก็บไว้แล้วส่งซ้ำ
 * ถ้าเซ็นแค่ body ใครที่ดักได้ครั้งหนึ่งจะส่งซ้ำได้ตลอดไป
 */
export function signBody(secret: string, signedAt: Date, rawBody: string): string {
  const payload = `${signedAt.toISOString()}.${rawBody}`
  return 'sha256=' + createHmac('sha256', secret).update(payload).digest('hex')
}

/**
 * ฝั่งร้านใช้ตรวจ · ใส่ไว้ที่นี่เป็นตัวอย่างให้เอาไปใช้ได้
 * เทียบด้วย timingSafeEqual · เทียบ string ธรรมดารั่วข้อมูลผ่านเวลา
 */
export function verifyWebhook(
  secret: string,
  signedAtHeader: string,
  rawBody: string,
  signature: string,
  maxAgeSeconds = 300,
): boolean {
  const t = Date.parse(signedAtHeader)
  if (Number.isNaN(t)) return false
  if (Math.abs(Date.now() - t) > maxAgeSeconds * 1000) return false

  const expected = signBody(secret, new Date(t), rawBody)
  const a = Buffer.from(expected, 'utf8')
  const b = Buffer.from(signature, 'utf8')
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

/** สถานะ → ชนิด event ที่ร้านลงทะเบียนไว้ */
export function eventTypeOf(s: OperationStatus): string {
  switch (s) {
    case 'PENDING':        return 'operation.pending'
    case 'SUBMITTED':      return 'operation.submitted'
    case 'CONFIRMED':      return 'operation.confirmed'
    case 'FINALIZED':      return 'operation.finalized'
    case 'CHAIN_REVERTED': return 'operation.reverted'
    case 'ORPHANED':       return 'operation.orphaned'
    case 'MANUAL_REVIEW':  return 'operation.review'
  }
}

function short(): string {
  return randomUUID().replace(/-/g, '').slice(0, 12)
}
