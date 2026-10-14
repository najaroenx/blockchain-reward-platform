/**
 * FEAT-05 · ชั้น ADMIT ของการโอน point
 *
 * สิ่งที่ feature นี้ต่างจากชุดก่อน
 *   1 · ยอดบวกกันได้ จึงใช้ unique index กันเกินยอดไม่ได้
 *       ความถูกต้องมาจาก trigger ที่ตรวจผลรวมใต้ advisory lock
 *   2 · หนึ่งคำขอคือหนึ่ง operation แต่บน chain แบ่งเป็นหลาย tx
 *   3 · ปล่อยยอดที่จองไว้ได้เมื่องานจบเท่านั้น · trigger บังคับอีกชั้น
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  AdmitResult, TransferRequest, MerchantId, PointTypeId, OperationId, BaseUnits,
  Recipient, HolderKind,
} from './types'
import {
  toBaseUnits, sumBaseUnits, isBaseUnits, pointBalanceKey, chunk,
  MAX_RECIPIENTS_PER_STEP, MAX_RECIPIENTS_PER_REQUEST, expiryOf, epochOf,
} from './types'
import { createHash, randomUUID } from 'node:crypto'

export function fingerprint(dto: unknown): Buffer {
  const canonical = JSON.stringify(dto, Object.keys(dto as object).sort())
  return createHash('sha256').update(canonical.normalize('NFC')).digest()
}

export class ValidationError extends Error {
  constructor(readonly field: string, readonly code: string, msg: string) {
    super(msg)
  }
}

export class TransferService {
  constructor(private readonly db: PrismaClient) {}

  async transfer(
    merchantId: MerchantId,
    idempotencyKey: string,
    dto: TransferRequest,
  ): Promise<AdmitResult> {
    // ---- validate ก่อนแตะฐานข้อมูล ------------------------------------
    if (dto.recipients.length < 1 || dto.recipients.length > MAX_RECIPIENTS_PER_REQUEST)
      throw new ValidationError('recipients', 'VALIDATION_FAILED',
        `ผู้รับต้องมี 1-${MAX_RECIPIENTS_PER_REQUEST} คน`)

    const seen = new Set<string>()
    for (const [i, r] of dto.recipients.entries()) {
      if (!isBaseUnits(r.amount))
        throw new ValidationError(`recipients[${i}].amount`, 'VALIDATION_FAILED',
          'amount ต้องเป็น string ของเลขจำนวนเต็ม')
      if (BigInt(r.amount) <= 0n)
        throw new ValidationError(`recipients[${i}].amount`, 'VALIDATION_FAILED',
          'amount ต้องมากกว่า 0')
      if (seen.has(r.customerId))
        throw new ValidationError('recipients', 'DUPLICATE_RECIPIENT',
          `${r.customerId} ปรากฏมากกว่าหนึ่งครั้ง`)
      seen.add(r.customerId)
    }

    const total = sumBaseUnits(dto.recipients.map((r) => r.amount))
    const scope = `merchant:${merchantId}`
    const fp = fingerprint(dto)

    return this.db.$transaction(async (tx) => {
      // ---- R1 · สเตตเมนต์แรกของ transaction เสมอ -----------------------
      const inserted = await tx.$executeRaw`
        INSERT INTO idempotency_key (id, scope, key, fingerprint, expires_at)
        VALUES (${'ik_' + short()}, ${scope}, ${idempotencyKey},
                ${fp}, now() + interval '72 hours')
        ON CONFLICT (scope, key) DO NOTHING`

      if (inserted === 0) {
        const prior = await tx.idempotencyKey.findUnique({
          where: { scope_key: { scope, key: idempotencyKey } },
        })
        if (!prior) throw new Error('invariant: ON CONFLICT แต่หาแถวเดิมไม่เจอ')
        if (!prior.fingerprint.equals(fp))
          return { outcome: 'conflict', code: 'IDEMPOTENCY_KEY_REUSED' } as const
        if (prior.responseStatus === null)
          return { outcome: 'conflict', code: 'IDEMPOTENCY_KEY_IN_PROGRESS' } as const
        return { outcome: 'replayed', status: prior.responseStatus, body: prior.responseBody }
      }

      // ---- point type ต้องเป็นของร้านนี้ และ LIVE ------------------------
      const pt = await tx.pointType.findFirst({
        where: { id: dto.pointTypeId, merchantId },
        include: { chain: true },
      })
      if (!pt) throw new ValidationError('pointTypeId', 'POINT_TYPE_NOT_FOUND', 'ไม่พบ point type')
      if (pt.status !== 'LIVE')
        throw new ValidationError('pointTypeId', 'POINT_TYPE_NOT_LIVE',
          `point type อยู่สถานะ ${pt.status}`)

      const operationId = ('op_' + short()) as OperationId
      const batches = chunk(dto.recipients, MAX_RECIPIENTS_PER_STEP)

      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: scope,
          kind: 'POINT_TRANSFER',
          status: 'PENDING',
          subjectId: dto.pointTypeId,
          payload: {
            pointTypeId: dto.pointTypeId,
            recipients: dto.recipients as unknown as Prisma.InputJsonValue,
            note: dto.note ?? null,
          } as Prisma.InputJsonValue,
        },
      })

      await tx.operationStep.createMany({
        data: batches.map((b, i) => ({
          id: 'st_' + short(),
          operationId,
          stepIndex: i + 1,
          name: 'batchTransfer',
          recipientCount: b.length,
        })),
      })

      // ---- จองยอด · ไม่เช็คเองว่าพอไหม ---------------------------------
      // trigger trg_point_reservation_balance ตรวจผลรวมใต้ advisory lock
      // ถ้าเช็คเองด้วย SELECT ก่อน จะมีช่องให้คำขออื่นแทรกระหว่างทาง
      try {
        await tx.reservation.create({
          data: {
            id: 'rsv_' + short(),
            operationId,
            subjectType: 'POINT_BALANCE',
            subjectId: pointBalanceKey(dto.pointTypeId, 'MERCHANT', merchantId),
            amount: total,
          },
        })
      } catch (e) {
        if (isCheckViolation(e)) {
          const available = await this.availableOf(tx, dto.pointTypeId, 'MERCHANT', merchantId)
          return { outcome: 'insufficient', requested: total, available }
        }
        throw e
      }

      await tx.outbox.create({
        data: {
          id: 'obx_' + short(),
          operationId,
          topic: 'point.transfer.v1',
          payload: { pointTypeId: dto.pointTypeId, steps: batches.length } as Prisma.InputJsonValue,
        },
      })

      await tx.operationEvent.create({
        data: { id: 'oev_' + short(), operationId, toStatus: 'PENDING', actor: 'MERCHANT_ADMIN' },
      })

      const body = {
        operationId,
        status: 'PENDING' as const,
        pointTypeId: dto.pointTypeId,
        recipientCount: dto.recipients.length,
        totalAmount: total,
        stepCount: batches.length,
        reservedUntilFinal: true as const,
      }

      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 202, responseBody: body },
      })

      return { outcome: 'created', operationId, stepCount: batches.length, totalAmount: total }
    })
  }

  /** ยอดที่ใช้ได้ · เรียกฟังก์ชันเดียวกับที่ trigger ใช้ จะได้ไม่มีสองสูตร */
  private async availableOf(
    tx: { $queryRaw(s: TemplateStringsArray, ...v: unknown[]): Promise<unknown[]> },
    pointTypeId: PointTypeId,
    holderKind: HolderKind,
    holderId: string,
  ): Promise<BaseUnits> {
    const rows = (await tx.$queryRaw`
      SELECT f_available_points(${pointTypeId}, ${holderKind}::holder_kind,
                                ${holderId}, now())::text AS v`) as { v: string }[]
    return toBaseUnits(rows[0]?.v ?? '0')
  }
}

// =====================================================================
// ฝั่ง projector · เขียน bucket และ ledger จาก chain_event
// =====================================================================
export interface TransferEvent {
  operationId: OperationId
  pointTypeId: PointTypeId
  from: { kind: HolderKind; id: string }
  to: { kind: HolderKind; id: string }
  amount: BaseUnits
  blockTimestamp: Date
  chainEventId: string
}

export class TransferProjector {
  constructor(private readonly db: PrismaClient) {}

  /**
   * ยอดเข้า bucket ตาม epoch ที่ได้รับ
   * `expiresAt` คำนวณจากค่าคงที่ของ contract ไม่ใช่จากเวลาที่รัน projector
   * จึง replay กี่ครั้งก็ได้ค่าเดิม (RFD 10)
   */
  async apply(ev: TransferEvent): Promise<void> {
    const chain = await this.db.pointTypeChain.findUnique({
      where: { pointTypeId: ev.pointTypeId },
    })
    if (!chain) throw new Error(`ยังไม่มีค่า chain ของ ${ev.pointTypeId}`)

    const params = {
      genesisAt: chain.genesisAt,
      epochSeconds: chain.epochSeconds,
      validityEpochs: chain.validityEpochs,
    }
    const epochIndex = epochOf(params, ev.blockTimestamp)
    const expiresAt = expiryOf(params, ev.blockTimestamp)

    await this.db.$transaction(async (tx) => {
      // ผู้รับได้ยอดเข้า bucket ของ epoch นั้น
      await tx.$executeRaw`
        INSERT INTO point_balance_bucket
          (id, point_type_id, holder_kind, holder_id, epoch_index, amount, received_at, expires_at)
        VALUES (${'bkt_' + short()}, ${ev.pointTypeId}, ${ev.to.kind}::holder_kind,
                ${ev.to.id}, ${epochIndex}, ${ev.amount}::numeric,
                ${ev.blockTimestamp}, ${expiresAt})
        ON CONFLICT (point_type_id, holder_kind, holder_id, epoch_index)
        DO UPDATE SET amount = point_balance_bucket.amount + excluded.amount,
                      updated_at = now()`

      // ผู้ส่งถูกหักแบบ FIFO · bucket ที่ใกล้หมดอายุก่อน
      await this.deductFifo(tx, ev)

      // บัญชีคู่ · DEBIT ของผู้ส่งต้องเท่ากับ CREDIT ของผู้รับเสมอ
      await tx.ledgerEntry.createMany({
        data: [
          {
            id: 'le_' + short(), operationId: ev.operationId, pointTypeId: ev.pointTypeId,
            holderKind: ev.from.kind, holderId: ev.from.id,
            direction: 'DEBIT', amount: ev.amount, chainEventId: ev.chainEventId,
          },
          {
            id: 'le_' + short(), operationId: ev.operationId, pointTypeId: ev.pointTypeId,
            holderKind: ev.to.kind, holderId: ev.to.id,
            direction: 'CREDIT', amount: ev.amount, chainEventId: ev.chainEventId,
          },
        ],
      })
    })
  }

  /**
   * หักจาก bucket ที่ใกล้หมดอายุที่สุดก่อน
   * ลำดับนี้ต้องตรงกับที่ contract ทำ ไม่งั้นยอดในระบบกับบน chain จะเพี้ยน
   * (RFD 10 Q1 · ยังต้องยืนยันกับ contract จริง)
   */
  private async deductFifo(
    tx: { $executeRaw(s: TemplateStringsArray, ...v: unknown[]): Promise<number> },
    ev: TransferEvent,
  ): Promise<void> {
    await tx.$executeRaw`
      WITH ordered AS (
        SELECT id, amount,
               sum(amount) OVER (ORDER BY expires_at, id) AS running
          FROM point_balance_bucket
         WHERE point_type_id = ${ev.pointTypeId}
           AND holder_kind   = ${ev.from.kind}::holder_kind
           AND holder_id     = ${ev.from.id}
           AND expires_at    > ${ev.blockTimestamp}
           AND amount > 0
         ORDER BY expires_at, id
         FOR UPDATE
      ), plan AS (
        SELECT id,
               least(amount, greatest(${ev.amount}::numeric - (running - amount), 0)) AS take
          FROM ordered
         WHERE running - amount < ${ev.amount}::numeric
      )
      UPDATE point_balance_bucket b
         SET amount = b.amount - p.take, updated_at = now()
        FROM plan p WHERE b.id = p.id`
  }
}

function short(): string {
  return randomUUID().replace(/-/g, '').slice(0, 12)
}

/** trigger ของเราใช้ ERRCODE check_violation (23514) เวลายอดไม่พอ */
function isCheckViolation(e: unknown): boolean {
  const c = (e as { code?: string; meta?: { code?: string } }).code
    ?? (e as { meta?: { code?: string } }).meta?.code
  return c === '23514' || c === 'P2010'
}
