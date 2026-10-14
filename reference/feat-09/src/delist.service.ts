/**
 * FEAT-09 · ชั้น ADMIT ของการถอดรายการขาย
 *
 * สิ่งที่ feature นี้ต่างจากชุดก่อน
 *   1 · ไม่มีการตรวจสิทธิ์ในโค้ดเลย · ไม่มี SELECT listing มาเช็คก่อน
 *       trigger trg_delist_admissible ตรวจทั้งเจ้าของและสถานะ
 *       ในสเตตเมนต์เดียวกับที่สร้าง operation
 *   2 · service แปลง error ของฐานข้อมูลเป็น error code ของ API
 *       ไม่ใช่ตัดสินเองว่าควรผ่านหรือไม่
 *   3 · CHAIN_REVERTED เป็นผลลัพธ์ปกติของ feature นี้ ไม่ใช่ความผิดพลาด
 *
 * ทำไมไม่เช็คก่อน
 *   เช็คก่อนแล้วค่อยเขียน คือสองสเตตเมนต์ · ระหว่างสองสเตตเมนต์
 *   สถานะเปลี่ยนได้ และนั่นคือหน้าต่างเดียวกับที่ F1 กับ F5 อยู่
 *   ที่นี่การตัดสินกับการเขียนเป็นสเตตเมนต์เดียวกัน
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  ActorScope, CouponCodeId, DelistResult, ListingId, OperationId,
} from './types'
import { DELIST_STEPS, isDelistable } from './types'
import { createHash, randomUUID } from 'node:crypto'

/**
 * SPEC-001 [IK-23] · hash ตรงๆ · ห้าม salt / secret / HMAC
 * คำขอถอดมี parameter เดียวคือ listingId จึงเป็น fingerprint ของมันเลย
 */
export function fingerprint(listingId: ListingId): Buffer {
  return createHash('sha256').update(listingId.normalize('NFC')).digest()
}

export class DelistService {
  constructor(private readonly db: PrismaClient) {}

  async delist(
    scope: ActorScope,
    idempotencyKey: string,
    listingId: ListingId,
  ): Promise<DelistResult> {
    const fp = fingerprint(listingId)

    return this.db.$transaction(async (tx) => {
      // ---- R1 · สเตตเมนต์แรกของ transaction เสมอ -----------------------
      // ห้าม try/catch รอบ INSERT นี้ · สเตตเมนต์ที่ error ทำให้
      // transaction เข้าสถานะ aborted (25P02) แล้วทำอะไรต่อไม่ได้เลย
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

      const operationId = ('op_' + short()) as OperationId

      // ---- สร้าง operation · นี่คือจุดที่ฐานข้อมูลตัดสิน ------------------
      // trg_delist_admissible ตรวจสามเรื่องในสเตตเมนต์นี้
      //   ก  รายการมีอยู่จริงไหม       (F5 · "ไม่เจอ" = ปฏิเสธ)
      //   ข  เป็นของผู้เรียกไหม        (F5 · อ่านจาก actor_scope ไม่ใช่ body)
      //   ค  สถานะ ACTIVE ไหม
      // uq_listing_inflight ตรวจอีกเรื่อง
      //   ง  รายการนี้มีงานค้างอยู่ไหม  (คนกดซื้อ ชนะถ้าแทรกได้ก่อน)
      try {
        await tx.operation.create({
          data: {
            id: operationId,
            actorScope: scope,
            kind: 'LISTING_DELETE',
            status: 'PENDING',
            subjectId: listingId,
            payload: { listingId } as Prisma.InputJsonValue,
          },
        })
      } catch (e) {
        if (isUnique(e)) {
          // ชน uq_listing_inflight · มีงานค้างอยู่บนรายการนี้
          return { outcome: 'conflict', code: 'LISTING_BUSY' } as const
        }
        if (isCheck(e)) return classifyAdmitError(e)
        throw e
      }

      // สอง step เรียงกัน · ลำดับนี้ห้ามสลับ
      await tx.operationStep.createMany({
        data: DELIST_STEPS.map((name, i) => ({
          id: 'st_' + short(),
          operationId,
          stepIndex: i + 1,
          name,
        })),
      })

      // ไม่มีการจองอะไรเพิ่ม
      // คูปองถูกจองไว้แล้วตั้งแต่ FEAT-08 ด้วย operation LISTING_CREATE
      // และตัว listing เองก็ถูกจองไว้แล้วด้วย · uq_reservation_exclusive
      // จะไม่ยอมให้จองซ้อน · ตัวกันการถอดซ้ำคือ uq_listing_inflight
      // บนตาราง operation ไม่ใช่ reservation

      await tx.outbox.create({
        data: {
          id: 'obx_' + short(),
          operationId,
          topic: 'listing.delete.v1',
          payload: { listingId } as Prisma.InputJsonValue,
        },
      })

      await tx.operationEvent.create({
        data: {
          id: 'oev_' + short(),
          operationId,
          toStatus: 'PENDING',
          actor: scope.startsWith('admin:') ? 'PLATFORM_ADMIN' : 'MERCHANT_ADMIN',
          metadata: { by: scope } as Prisma.InputJsonValue,
        },
      })

      const body = {
        listingId,
        status: 'ACTIVE' as const,
        operationId,
        stepCount: DELIST_STEPS.length,
      }
      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 202, responseBody: body },
      })

      return { outcome: 'accepted', listingId, operationId }
    })
  }

  /**
   * ปล่อยคูปองคืนผู้ขาย · worker เรียกหลัง releaseFromVault FINALIZED
   *
   * ลำดับในนี้สำคัญ · ปิด listing ก่อน แล้วค่อยปล่อยจอง
   * trg_coupon_hold_until_closed จะปฏิเสธถ้าสลับลำดับ
   *
   * คูปองไม่เปลี่ยน state · ยัง HELD อยู่ในมือร้านเดิมตลอด
   * การลงขายเป็นเรื่องของ reservation ไม่ใช่ของ coupon_code.state
   */
  async settleDelisted(
    listingId: ListingId,
    chain: { closedBlock: bigint; closedTxHash: Buffer },
  ): Promise<{ released: number }> {
    return this.db.$transaction(async (tx) => {
      // 1 · projection ของ chain · เขียนเมื่อเห็น event แล้วเท่านั้น
      await tx.listingChain.update({
        where: { listingId },
        data: {
          closedBlock: chain.closedBlock,
          closedTxHash: chain.closedTxHash,
          closeReason: 'CANCELLED',
        },
      })

      // 2 · ปิดรายการ · trg_listing_status_transition เติม closed_at ให้เอง
      //     และปฏิเสธถ้าสถานะเดิมไม่ใช่ ACTIVE
      await tx.listing.update({
        where: { id: listingId },
        data: { status: 'DELISTED' },
      })

      // 3 · ปล่อยจองทั้งคูปองและตัวรายการ
      //     ต้องทำหลังขั้นที่ 2 · ไม่มีทางสลับได้เพราะ trigger กันไว้
      const released = await tx.$executeRaw`
        UPDATE reservation r
           SET released_at = now()
         WHERE r.released_at IS NULL
           AND (
                 (r.subject_type = 'LISTING' AND r.subject_id = ${listingId})
              OR (r.subject_type = 'COUPON_UNIT' AND r.subject_id IN (
                    SELECT coupon_code_id FROM listing_item WHERE listing_id = ${listingId}))
               )`

      return { released }
    })
  }

  /**
   * คนซื้อตัดหน้า · cancelListing revert บน chain
   *
   * นี่ไม่ใช่ error ของระบบ · เป็นผลลัพธ์ปกติของการแข่งกัน
   * operation จบที่ CHAIN_REVERTED และ "ไม่ทำอะไรกับของเลย"
   * คูปองยังอยู่ใน escrow เพราะรายการถูกซื้อไปแล้ว
   * การย้ายคูปองไปให้ผู้ซื้อเป็นงานของ FEAT-10 ไม่ใช่ของที่นี่
   */
  async markLostRace(operationId: OperationId, note: string): Promise<void> {
    await this.db.$transaction(async (tx) => {
      await tx.operation.update({
        where: { id: operationId },
        data: { status: 'CHAIN_REVERTED', errorNote: note },
      })
      await tx.operationEvent.create({
        data: {
          id: 'oev_' + short(),
          operationId,
          fromStatus: 'SUBMITTED',
          toStatus: 'CHAIN_REVERTED',
          metadata: { reason: 'LOST_RACE_TO_BUYER' } as Prisma.InputJsonValue,
        },
      })
    })
  }

  /**
   * ผู้ขายเห็น id ของคูปองในรายการตัวเอง · คนอื่นเห็นแค่จำนวน
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
      activeAt: l.activeAt?.toISOString() ?? null,
      closedAt: l.closedAt?.toISOString() ?? null,
      ...(isSeller
        ? {
            couponCodeIds: (l.items as { couponCodeId: string }[])
              .map((i) => i.couponCodeId as CouponCodeId),
          }
        : {}),
      chain: l.chain
        ? {
            contractAddress:
              ('0x' + (l.chain.contractAddress as Buffer).toString('hex')) as `0x${string}`,
            chainListingId: l.chain.chainListingId.toFixed(0),
            closeReason: l.chain.closeReason,
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
  return String((e as { message?: string }).message ?? '')
}

/**
 * แปลงข้อความจาก trg_delist_admissible เป็นคำตอบของ API
 *
 * "ไม่พบรายการขาย" และ "ไม่ใช่ของคุณ" คืน 404 เหมือนกันโดยตั้งใจ
 * คนนอกจึงเดาไม่ได้ว่า listingId ไหนมีอยู่จริง
 * ฐานข้อมูลแยกสองกรณีได้ และข้อความจริงอยู่ใน log ของ server
 */
function classifyAdmitError(e: unknown): DelistResult {
  const m = messageOf(e)
  if (m.includes('ไม่พบรายการขาย') || m.includes('ไม่ใช่ของ')) {
    return { outcome: 'notFound' }
  }
  if (m.includes('ถอดไม่ได้')) {
    return { outcome: 'conflict', code: 'LISTING_NOT_ACTIVE' }
  }
  // ข้อความที่ไม่รู้จัก ถือเป็นการปฏิเสธที่ปลอดภัยที่สุด
  return { outcome: 'notFound' }
}

/**
 * ตัวช่วยฝั่งอ่าน · ใช้ตอบคำถาม "ปุ่มถอดควรกดได้ไหม" ที่หน้าจอ
 * ไม่ได้ใช้ตัดสินใจอะไรในฝั่งเขียน · ฝั่งเขียนให้ฐานข้อมูลตัดสิน
 */
export function delistButtonEnabled(l: {
  status: string
  sellerKind: string
  sellerId: string
}, viewer: { kind: string; id: string }): boolean {
  return (
    isDelistable(l.status as never) &&
    l.sellerKind === viewer.kind &&
    l.sellerId === viewer.id
  )
}
