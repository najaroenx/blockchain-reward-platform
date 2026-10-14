/**
 * FEAT-11 · ชั้น ADMIT ของ redeem — โครงที่ dev เอาไปต่อได้ทันที
 *
 * ทุกบรรทัดที่สำคัญมีเลขกฎกำกับ · ลำดับในฟังก์ชันนี้คือสิ่งที่ห้ามสลับ
 * RFD 2 R1 · INSERT idempotency_key เป็นสเตตเมนต์แรก
 * RFD 2 R2 · raw_tx ลงตารางก่อน broadcast (อยู่ฝั่ง worker ไม่ใช่ไฟล์นี้)
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  AdmitInput, AdmitResult, OperationId, CouponCodeId, RedeemRequest, BaseUnits,
} from './types'
import { toBaseUnits } from './types'
import { createHash, randomUUID } from 'node:crypto'

/** sha256 ของ DTO ที่ normalize แล้ว · ห้ามใส่ salt/secret/HMAC (RFD 3 L7) */
export function fingerprint(dto: unknown): Buffer {
  const canonical = JSON.stringify(dto, Object.keys(dto as object).sort())
  return createHash('sha256').update(canonical.normalize('NFC')).digest()
}

export class RedeemService {
  constructor(private readonly db: PrismaClient) {}

  async redeem(
    actor: { scope: string; kind: 'CUSTOMER' | 'MERCHANT_ADMIN'; id: string },
    idempotencyKey: string,
    dto: RedeemRequest,
  ): Promise<AdmitResult> {
    const codeHash = createHash('sha256').update(dto.couponCode.toUpperCase()).digest()

    return this.db.$transaction(async (tx) => {
      // ---- R1 · สเตตเมนต์แรกของ transaction เสมอ -----------------------
      // ใช้ ON CONFLICT DO NOTHING แล้วนับแถว · ห้าม try/catch เพราะ 25P02
      const inserted = await tx.$executeRaw`
        INSERT INTO idempotency_key (id, scope, key, fingerprint, expires_at)
        VALUES (${'ik_' + randomUUID()}, ${actor.scope}, ${idempotencyKey},
                ${fingerprint(dto)}, now() + interval '72 hours')
        ON CONFLICT (scope, key) DO NOTHING`

      if (inserted === 0) {
        const prior = await tx.idempotencyKey.findUnique({
          where: { scope_key: { scope: actor.scope, key: idempotencyKey } },
        })
        if (!prior) throw new Error('invariant: ON CONFLICT แต่หาแถวเดิมไม่เจอ')
        if (!prior.fingerprint.equals(fingerprint(dto)))
          return { outcome: 'conflict', code: 'IDEMPOTENCY_KEY_REUSED' } as const
        if (prior.responseStatus === null)
          return { outcome: 'conflict', code: 'IDEMPOTENCY_KEY_IN_PROGRESS' } as const
        return { outcome: 'replayed', status: prior.responseStatus, body: prior.responseBody }
      }

      // ---- สิทธิ์อยู่ใน WHERE ไม่ใช่ใน if (RFD 16 D4) ------------------
      // หาไม่เจอกับไม่ใช่เจ้าของ ตอบเหมือนกัน เพื่อไม่ให้เดารหัสได้
      const code = await tx.couponCode.findFirst({
        where: {
          codeHash,
          state: 'HELD',
          holderKind: actor.kind === 'CUSTOMER' ? 'CUSTOMER' : 'MERCHANT',
          holderId: actor.id,
        },
        include: { couponType: true },
      })
      if (!code) throw new NotFound('COUPON_NOT_FOUND')
      if (code.couponType.expiresAt && code.couponType.expiresAt < new Date())
        throw new Unprocessable('COUPON_EXPIRED')

      const escrow = await tx.escrow.findFirst({
        where: {
          contractAddress: code.couponType.contractAddress,
          chainTokenId: code.couponType.chainTypeId,
          active: true,
        },
      })
      if (!escrow) throw new Unprocessable('ESCROW_INSUFFICIENT')

      const perCoupon = toBaseUnits(
        BigInt(escrow.totalAmount.toFixed(0)) / BigInt(escrow.couponsLocked),
      )

      // ---- ADMIT · ทุกแถวหรือไม่มีเลย ---------------------------------
      const operationId = ('op_' + randomUUID().replace(/-/g, '').slice(0, 12)) as OperationId

      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: actor.scope,
          kind: 'COUPON_REDEEM',
          status: 'PENDING',
          payload: { couponCodeId: code.id, escrowId: escrow.id } as Prisma.InputJsonValue,
        },
      })

      // redeem = 2 step · ลำดับนี้ห้ามสลับ (RFD 13 §3.6)
      // burn ก่อน · ถ้า step 2 ล้ม เงินยังค้างใน vault ที่กู้ได้
      // ถ้าสลับ เงินออกไปแล้วแต่ coupon ยังใช้ได้ = กู้ไม่ได้
      await tx.operationStep.createMany({
        data: [
          { id: 'st_' + randomUUID(), operationId, stepIndex: 1, name: 'burnCoupon' },
          { id: 'st_' + randomUUID(), operationId, stepIndex: 2, name: 'releaseFundsPartial' },
        ],
      })

      // partial unique index ทำให้แถวที่สองบน coupon ใบเดิม insert ไม่ได้
      // นี่คือสิ่งที่กัน double-burn ไม่ใช่การเช็ค state ข้างบน (RFD 11 D4)
      await tx.reservation.createMany({
        data: [
          { id: 'rsv_' + randomUUID(), operationId, subjectType: 'COUPON_UNIT', subjectId: code.id, amount: '1' },
          { id: 'rsv_' + randomUUID(), operationId, subjectType: 'ESCROW', subjectId: escrow.id, amount: perCoupon },
        ],
      })

      // commit พร้อม operation เสมอ · งานจึงหายไม่ได้ (RFD 2 D1)
      await tx.outbox.create({
        data: {
          id: 'obx_' + randomUUID(),
          operationId,
          topic: 'operation.prepared.v1',
          payload: { kind: 'COUPON_REDEEM' } as Prisma.InputJsonValue,
        },
      })

      await tx.operationEvent.create({
        data: { id: 'oev_' + randomUUID(), operationId, toStatus: 'PENDING', actor: 'SYSTEM' },
      })

      const body = {
        operationId,
        status: 'PENDING' as const,
        couponCodeId: code.id as CouponCodeId,
        settlement: { amount: perCoupon, currency: 'THB', decimals: 18 },
      }

      await tx.idempotencyKey.update({
        where: { scope_key: { scope: actor.scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 202, responseBody: body },
      })

      return { outcome: 'created', operationId }
    })
    // หลัง COMMIT: ยิง queue เพื่อให้ worker รู้เร็วขึ้น
    // ยิงไม่สำเร็จไม่เป็นไร · worker จะเจอแถวใน outbox เองในรอบถัดไป
  }
}

export class NotFound extends Error {}
export class Unprocessable extends Error {}

/** ยอดต่อหนึ่งคูปองหารไม่ลงตัว เศษตกที่ใบสุดท้าย · ห้ามปัดเศษหาย (RFD 14 D8) */
export function splitEvenly(total: BaseUnits, parts: number): BaseUnits[] {
  const t = BigInt(total), n = BigInt(parts)
  const base = t / n, rem = t % n
  return Array.from({ length: parts }, (_, i) =>
    toBaseUnits(base + (BigInt(i) < rem ? 1n : 0n)))
}
