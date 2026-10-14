/**
 * FEAT-07 · ชั้น ADMIT ของการสร้างประเภทคูปองและการออกรหัส
 *
 * สามเรื่องที่ต้องระวังเป็นพิเศษใน feature นี้
 *   1 · plaintext ของรหัสอยู่ในหน่วยความจำของ request นี้เท่านั้น
 *       ห้ามเขียนลงฐานข้อมูล ห้าม log ห้ามใส่ใน payload ของ operation
 *   2 · codeRef ต้องเป็น sha256(id) เสมอ · trigger จะปฏิเสธถ้าคำนวณผิด
 *   3 · โควตาตัดสินด้วย trigger ไม่ใช่ SELECT มานับก่อน
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  CreateTypeResult, IssueResult, CreateCouponTypeRequest, IssueRequest,
  MerchantId, CouponTypeId, CouponCodeId, BatchId, OperationId, IssuedCode,
} from './types'
import {
  isBaseUnits, generateCode, codeHashOf, codeRefOf, chunkSizes,
  MAX_ISSUE_PER_REQUEST, ISSUE_WARNING,
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

export class CouponService {
  constructor(private readonly db: PrismaClient) {}

  // =================================================================
  // 1 · สร้างประเภทคูปอง
  // =================================================================
  async createType(
    merchantId: MerchantId,
    idempotencyKey: string,
    dto: CreateCouponTypeRequest,
  ): Promise<CreateTypeResult> {
    const name = dto.name.normalize('NFC').trim()
    if (name.length < 1 || name.length > 120)
      throw new ValidationError('name', 'VALIDATION_FAILED', 'ชื่อต้องยาว 1-120 ตัวอักษร')
    if (!isBaseUnits(dto.faceValue))
      throw new ValidationError('faceValue', 'VALIDATION_FAILED',
        'faceValue ต้องเป็น string ของเลขจำนวนเต็ม')
    if (!Number.isInteger(dto.totalSupply) || dto.totalSupply < 1 || dto.totalSupply > 1_000_000)
      throw new ValidationError('totalSupply', 'VALIDATION_FAILED',
        'totalSupply ต้องอยู่ในช่วง 1-1,000,000')

    const expiresAt = new Date(dto.expiresAt)
    if (Number.isNaN(expiresAt.getTime()) || expiresAt <= new Date())
      throw new ValidationError('expiresAt', 'VALIDATION_FAILED', 'expiresAt ต้องอยู่ในอนาคต')

    const scope = `merchant:${merchantId}`
    const fp = fingerprint({ ...dto, name })

    return this.db.$transaction(async (tx) => {
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

      const couponTypeId = ('ct_' + short()) as CouponTypeId
      const operationId = ('op_' + short()) as OperationId

      // ไม่ SELECT มาเช็คชื่อซ้ำก่อน · ปล่อยให้ uq_coupon_type_name ตัดสิน
      // trigger trg_coupon_type_merchant_active จะ raise ถ้าร้านยังไม่ ACTIVE
      try {
        await tx.couponType.create({
          data: {
            id: couponTypeId,
            merchantId,
            name,
            faceValue: dto.faceValue,
            totalSupply: dto.totalSupply,
            status: 'REQUESTED',
            expiresAt,
          },
        })
      } catch (e) {
        if (isUnique(e)) return { outcome: 'conflict', code: 'NAME_TAKEN' } as const
        throw e
      }

      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: scope,
          kind: 'COUPON_TYPE_CREATE',
          status: 'PENDING',
          subjectId: couponTypeId,
          payload: { couponTypeId, name, totalSupply: dto.totalSupply } as Prisma.InputJsonValue,
        },
      })
      await tx.operationStep.create({
        data: { id: 'st_' + short(), operationId, stepIndex: 1, name: 'createCouponType' },
      })
      await tx.outbox.create({
        data: {
          id: 'obx_' + short(),
          operationId,
          topic: 'coupon.type.create.v1',
          payload: { couponTypeId } as Prisma.InputJsonValue,
        },
      })
      await tx.operationEvent.create({
        data: { id: 'oev_' + short(), operationId, toStatus: 'PENDING', actor: 'MERCHANT_ADMIN' },
      })

      const body = {
        couponTypeId,
        name,
        faceValue: dto.faceValue,
        totalSupply: dto.totalSupply,
        status: 'REQUESTED' as const,
        expiresAt: expiresAt.toISOString(),
        operationId,
      }
      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 202, responseBody: body },
      })

      return { outcome: 'created', couponTypeId, operationId }
    })
  }

  // =================================================================
  // 2 · ออกรหัสเป็นชุด
  // =================================================================
  /**
   * **plaintext ของรหัสไม่ถูกเขียนลงที่ไหนเลย**
   * มันอยู่ในตัวแปร `issued` ของฟังก์ชันนี้ แล้วออกไปกับ response ครั้งเดียว
   *
   * สังเกตว่า `operation.payload` และ `outbox.payload` มีแต่ `couponCodeId`
   * ไม่มีรหัส · ถ้าใส่เข้าไป มันจะไปโผล่ใน log และใน replay ของ idempotency
   */
  async issue(
    merchantId: MerchantId,
    couponTypeId: CouponTypeId,
    idempotencyKey: string,
    dto: IssueRequest,
  ): Promise<IssueResult> {
    if (!Number.isInteger(dto.quantity) || dto.quantity < 1 || dto.quantity > MAX_ISSUE_PER_REQUEST)
      throw new ValidationError('quantity', 'VALIDATION_FAILED',
        `quantity ต้องอยู่ในช่วง 1-${MAX_ISSUE_PER_REQUEST}`)

    const scope = `merchant:${merchantId}`
    const fp = fingerprint({ couponTypeId, quantity: dto.quantity })

    return this.db.$transaction(async (tx) => {
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
        // replay จะไม่มีรหัสอยู่ใน body เพราะเราไม่เคยเก็บมัน
        return { outcome: 'replayed', status: prior.responseStatus, body: prior.responseBody }
      }

      const ct = await tx.couponType.findFirst({
        where: { id: couponTypeId, merchantId },
      })
      if (!ct) throw new ValidationError('couponTypeId', 'COUPON_TYPE_NOT_FOUND', 'ไม่พบประเภทคูปอง')
      if (ct.status !== 'LIVE')
        throw new ValidationError('couponTypeId', 'COUPON_TYPE_NOT_LIVE',
          `ประเภทคูปองอยู่สถานะ ${ct.status}`)
      if ((ct.expiresAt as Date) <= new Date())
        throw new ValidationError('couponTypeId', 'COUPON_TYPE_EXPIRED', 'ประเภทคูปองหมดอายุแล้ว')

      const batchId = ('ib_' + short()) as BatchId
      const operationId = ('op_' + short()) as OperationId
      const sizes = chunkSizes(dto.quantity)

      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: scope,
          kind: 'COUPON_ISSUE',
          status: 'PENDING',
          subjectId: couponTypeId,
          // payload ไม่มีรหัส · มีแต่จำนวน
          payload: { couponTypeId, quantity: dto.quantity } as Prisma.InputJsonValue,
        },
      })
      await tx.issueBatch.create({
        data: { id: batchId, couponTypeId, operationId, quantity: dto.quantity },
      })
      await tx.operationStep.createMany({
        data: sizes.map((n, i) => ({
          id: 'st_' + short(),
          operationId,
          stepIndex: i + 1,
          name: 'mintCoupon',
          mintCount: n,
        })),
      })

      // ---- สร้างรหัสทีละใบ ---------------------------------------------
      // trigger trg_issue_within_supply ตรวจโควตาทุกแถว ถ้าเกินจะ raise
      // จึงไม่ต้อง SELECT มานับก่อน · และไม่มีช่องให้คำขออื่นแทรก
      const issued: IssuedCode[] = []
      try {
        for (let i = 0; i < dto.quantity; i++) {
          const codeId = ('cc_' + short()) as CouponCodeId
          const plaintext = generateCode()
          await tx.couponCode.create({
            data: {
              id: codeId,
              couponTypeId,
              codeHash: codeHashOf(plaintext),
              // ต้องตรงกับ sha256(convert_to(id,'UTF8')) ใน trigger เป๊ะ
              codeRef: codeRefOf(codeId),
              state: 'ISSUED',
              issueBatchId: batchId,
            },
          })
          issued.push({ couponCodeId: codeId, code: plaintext })
        }
      } catch (e) {
        if (isCheck(e)) {
          const remaining = await this.remainingSupply(tx, couponTypeId, ct.totalSupply)
          return { outcome: 'supplyExceeded', requested: dto.quantity, remaining }
        }
        throw e
      }

      await tx.outbox.create({
        data: {
          id: 'obx_' + short(),
          operationId,
          topic: 'coupon.issue.v1',
          // payload ไม่มีรหัส · worker ใช้ codeRef ที่คำนวณจาก id ได้เอง
          payload: { batchId, couponTypeId, steps: sizes.length } as Prisma.InputJsonValue,
        },
      })
      await tx.operationEvent.create({
        data: { id: 'oev_' + short(), operationId, toStatus: 'PENDING', actor: 'MERCHANT_ADMIN' },
      })

      // body ที่เก็บลง idempotency_key ไม่มีรหัส
      // ถ้าเก็บ การ replay จะส่งรหัสออกไปอีกครั้ง ซึ่งขัดกับ "ส่งครั้งเดียว"
      const storedBody = {
        batchId,
        couponTypeId,
        operationId,
        quantity: dto.quantity,
        stepCount: sizes.length,
        codes: [],
        warning: 'รหัสถูกส่งไปแล้วในการเรียกครั้งแรก ไม่สามารถขอซ้ำได้',
      }
      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 202, responseBody: storedBody },
      })

      return {
        outcome: 'created',
        body: {
          batchId,
          couponTypeId,
          operationId,
          quantity: dto.quantity,
          stepCount: sizes.length,
          codes: issued,
          warning: ISSUE_WARNING,
        },
      }
    })
  }

  /** ใช้ตอนตอบ error ว่าเหลือออกได้อีกกี่ใบ */
  private async remainingSupply(
    tx: { couponCode: { count(a: unknown): Promise<number> } },
    couponTypeId: CouponTypeId,
    totalSupply: number,
  ): Promise<number> {
    const used = await tx.couponCode.count({
      where: { couponTypeId, state: { not: 'VOIDED' } },
    })
    return Math.max(totalSupply - used, 0)
  }

  /**
   * ตรวจรหัสที่ลูกค้ายื่นมา · ค้นด้วย hash ไม่ใช่ด้วย plaintext
   * ระบบไม่มีทางรู้รหัสจากฐานข้อมูล ทำได้แค่ยืนยันว่ารหัสที่ยื่นมาตรงกับใบไหน
   */
  async findByCode(plaintext: string): Promise<{ id: CouponCodeId; state: string } | null> {
    const row = await this.db.couponCode.findUnique({
      where: { codeHash: codeHashOf(plaintext) },
    })
    return row ? { id: row.id as CouponCodeId, state: row.state } : null
  }
}

function short(): string {
  return randomUUID().replace(/-/g, '').slice(0, 12)
}

function isUnique(e: unknown): boolean {
  const c = (e as { code?: string }).code
  return c === 'P2002' || c === '23505'
}

function isCheck(e: unknown): boolean {
  const c = (e as { code?: string }).code
  return c === '23514' || c === 'P2010'
}
