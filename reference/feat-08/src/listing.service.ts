/**
 * FEAT-08 · ชั้น ADMIT ของการลงขาย
 *
 * สิ่งที่ feature นี้ต่างจากชุดก่อน
 *   1 · เป็นงานสาม step ที่ต้องเรียงกัน · worker ยิงทีละขั้น ไม่ขนานกัน
 *   2 · เงื่อนไขของคูปองทุกข้อถูกตรวจที่ฐานข้อมูล ไม่ใช่ที่โค้ด
 *       เพราะระบบเดิมเช็คที่ api แล้วมีทางลัดที่ข้ามไปได้ (F5)
 *   3 · การจองคูปองใช้ partial unique index ไม่ใช่การ SELECT มาเช็คก่อน
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  AdmitResult, CreateListingRequest, MerchantId, ListingId, OperationId, CouponCodeId,
} from './types'
import {
  isBaseUnits, totalPriceOf, LISTING_STEPS, MAX_CODES_PER_LISTING,
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

export class ListingService {
  constructor(private readonly db: PrismaClient) {}

  async create(
    merchantId: MerchantId,
    idempotencyKey: string,
    dto: CreateListingRequest,
  ): Promise<AdmitResult> {
    // ---- validate ที่โค้ดทำได้เร็วกว่า -------------------------------
    if (!isBaseUnits(dto.unitPrice) || BigInt(dto.unitPrice) <= 0n)
      throw new ValidationError('unitPrice', 'VALIDATION_FAILED',
        'unitPrice ต้องเป็น string ของเลขจำนวนเต็มที่มากกว่า 0')

    const codes = dto.couponCodeIds
    if (codes.length < 1 || codes.length > MAX_CODES_PER_LISTING)
      throw new ValidationError('couponCodeIds', 'VALIDATION_FAILED',
        `ต้องมี 1-${MAX_CODES_PER_LISTING} ใบ`)

    const seen = new Set<string>()
    for (const c of codes) {
      if (seen.has(c))
        throw new ValidationError('couponCodeIds', 'DUPLICATE_CODE',
          `${c} ปรากฏมากกว่าหนึ่งครั้ง`)
      seen.add(c)
    }

    const scope = `merchant:${merchantId}`
    const fp = fingerprint(dto)
    const totalPrice = totalPriceOf(dto.unitPrice, codes.length)

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

      const listingId = ('lst_' + short()) as ListingId
      const operationId = ('op_' + short()) as OperationId

      await tx.listing.create({
        data: {
          id: listingId,
          sellerKind: 'MERCHANT',
          sellerId: merchantId,
          couponTypeId: dto.couponTypeId,
          unitPrice: dto.unitPrice,
          quantity: codes.length,
          status: 'PENDING',
        },
      })

      // ---- ใส่คูปองทีละใบ · ไม่เช็คเงื่อนไขเองเลย ------------------------
      // trigger trg_listing_item_valid ตรวจครบทุกข้อ
      //   สถานะ HELD · อยู่ในมือผู้ขาย · ประเภทตรงกัน · ยังไม่หมดอายุ
      // เช็คที่โค้ดก่อนแล้วค่อย INSERT จะมีช่องให้สถานะเปลี่ยนระหว่างทาง
      try {
        for (const [i, codeId] of codes.entries()) {
          await tx.listingItem.create({
            data: { id: 'li_' + short(), listingId, couponCodeId: codeId },
          })
          void i
        }
      } catch (e) {
        if (isCheck(e)) {
          return {
            outcome: 'rejected',
            code: classifyItemError(e),
            message: messageOf(e),
          }
        }
        throw e
      }

      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: scope,
          kind: 'LISTING_CREATE',
          status: 'PENDING',
          subjectId: listingId,
          payload: {
            listingId,
            couponTypeId: dto.couponTypeId,
            quantity: codes.length,
          } as Prisma.InputJsonValue,
        },
      })

      // สาม step เรียงกัน · ลำดับนี้ห้ามสลับ
      await tx.operationStep.createMany({
        data: LISTING_STEPS.map((name, i) => ({
          id: 'st_' + short(),
          operationId,
          stepIndex: i + 1,
          name,
        })),
      })

      // ---- จองคูปองทุกใบ และจองตัวรายการขายเอง ---------------------------
      // uq_reservation_exclusive เป็นตัวตัดสินว่าใบไหนถูกลงขายไปแล้ว
      try {
        await tx.reservation.createMany({
          data: [
            ...codes.map((codeId) => ({
              id: 'rsv_' + short(),
              operationId,
              subjectType: 'COUPON_UNIT' as const,
              subjectId: codeId,
              amount: '1',
            })),
            {
              id: 'rsv_' + short(),
              operationId,
              subjectType: 'LISTING' as const,
              subjectId: listingId,
              amount: '1',
            },
          ],
        })
      } catch (e) {
        if (isUnique(e)) return { outcome: 'conflict', code: 'CODE_ALREADY_LISTED' } as const
        throw e
      }

      await tx.outbox.create({
        data: {
          id: 'obx_' + short(),
          operationId,
          topic: 'listing.create.v1',
          payload: { listingId } as Prisma.InputJsonValue,
        },
      })

      await tx.operationEvent.create({
        data: { id: 'oev_' + short(), operationId, toStatus: 'PENDING', actor: 'MERCHANT_ADMIN' },
      })

      const body = {
        listingId,
        couponTypeId: dto.couponTypeId,
        unitPrice: dto.unitPrice,
        quantity: codes.length,
        totalPrice,
        status: 'PENDING' as const,
        operationId,
        stepCount: LISTING_STEPS.length,
      }
      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 202, responseBody: body },
      })

      return { outcome: 'created', listingId, operationId, totalPrice }
    })
  }

  /**
   * ผู้ขายเห็น id ของคูปองในรายการตัวเอง · คนอื่นเห็นแค่จำนวน
   * ไม่ใช่เพราะ id เป็นความลับ แต่เพราะคนซื้อไม่มีเหตุผลต้องเห็นก่อนซื้อ
   */
  async view(listingId: ListingId, viewer: { kind: string; id: string }) {
    const l = await this.db.listing.findUnique({
      where: { id: listingId },
      include: { items: true, chain: true },
    })
    if (!l) return null
    const isSeller = l.sellerKind === viewer.kind && l.sellerId === viewer.id
    return {
      listingId: l.id as ListingId,
      sellerKind: l.sellerKind,
      sellerId: l.sellerId,
      couponTypeId: l.couponTypeId,
      unitPrice: l.unitPrice.toFixed(0),
      quantity: l.quantity,
      status: l.status,
      ...(isSeller
        ? { couponCodeIds: (l.items as { couponCodeId: string }[]).map((i) => i.couponCodeId as CouponCodeId) }
        : {}),
      chain: l.chain
        ? {
            contractAddress: ('0x' + (l.chain.contractAddress as Buffer).toString('hex')) as `0x${string}`,
            chainListingId: l.chain.chainListingId.toFixed(0),
          }
        : null,
    }
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

function messageOf(e: unknown): string {
  return String((e as { message?: string }).message ?? 'คูปองไม่ผ่านเงื่อนไขการลงขาย')
}

/**
 * แปลงข้อความจาก trigger เป็น error code ของ API
 * trigger เขียนข้อความเป็นภาษาไทยไว้แล้ว จึงจับคำที่แยกกรณีได้
 */
function classifyItemError(
  e: unknown,
): 'NOT_CODE_HOLDER' | 'CODE_NOT_HELD' | 'CODE_EXPIRED' | 'CODE_TYPE_MISMATCH' {
  const m = messageOf(e)
  if (m.includes('ไม่ได้อยู่ในมือผู้ขาย')) return 'NOT_CODE_HOLDER'
  if (m.includes('หมดอายุ')) return 'CODE_EXPIRED'
  if (m.includes('คนละประเภท')) return 'CODE_TYPE_MISMATCH'
  return 'CODE_NOT_HELD'
}
