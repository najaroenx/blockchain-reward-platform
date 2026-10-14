/**
 * FEAT-10 · ชั้น ADMIT ของการซื้อ
 *
 * สิ่งที่ feature นี้ต่างจากชุดก่อน
 *   1 · เงินเคลื่อนจริง · ทุกการเคลื่อนเขียนลง ledger_entry ที่ต้องรวมได้ศูนย์
 *   2 · ยอดไม่พอคือการปฏิเสธ ไม่ใช่สัญญาณให้เสกเงิน (F4)
 *   3 · ตอนรับคำขอ "กันเงิน" ไม่ใช่ "ย้ายเงิน"
 *       เงินยังอยู่ในบัญชีผู้ซื้อ · ยอดที่ใช้ได้ลดลงเท่านั้น
 *       tx revert จึงแค่ปล่อยการจอง ไม่ต้องย้ายเงินกลับ
 *
 * ลำดับใน admit() สำคัญมาก
 *   idempotency ก่อน · operation ก่อน reservation
 *   เพราะ reservation อ้าง operation_id และ trigger ตรวจยอดตอน INSERT
 *   ถ้าจองก่อนสร้าง operation จะไม่มี row ให้อ้าง
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  ActorScope, BaseUnits, BuyResult, HolderKind, LedgerLine,
  ListingId, Money, OperationId, PurchaseId,
} from './types'
import {
  BUY_STEPS, accountKey, ledgerAccountOf, ledgerBalances,
  moneyBalances, priceOf, purchaseLedger, toBaseUnits,
} from './types'
import { createHash, randomUUID } from 'node:crypto'

const PLATFORM_ACCOUNT_ID = 'platform'

/** SPEC-001 [IK-23] · hash ตรงๆ · ห้าม salt / secret / HMAC */
export function fingerprint(listingId: ListingId, body: unknown): Buffer {
  const canonical = JSON.stringify({ listingId, body })
  return createHash('sha256').update(canonical.normalize('NFC')).digest()
}

export class PriceMismatch extends Error {
  constructor(readonly expected: BaseUnits, readonly actual: BaseUnits) {
    super(`ยอดที่หน้าจอถือไว้ ${expected} ไม่ตรงกับที่คำนวณได้ ${actual}`)
  }
}

export class PurchaseService {
  constructor(private readonly db: PrismaClient) {}

  async admit(
    scope: ActorScope,
    buyer: { kind: HolderKind; id: string },
    idempotencyKey: string,
    listingId: ListingId,
    expectedTotalPrice: BaseUnits,
  ): Promise<BuyResult> {
    const fp = fingerprint(listingId, { expectedTotalPrice })

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

      // ---- อ่านรายการขายเพื่อ "คิดเงิน" ไม่ใช่เพื่อ "ตรวจสิทธิ์" -----------
      // การตรวจสิทธิ์เป็นงานของ trg_buy_admissible ในสเตตเมนต์ถัดไป
      // ที่นี่อ่านมาเพราะต้องรู้ราคาและจำนวนเพื่อคำนวณ
      const listing = await tx.listing.findUnique({ where: { id: listingId } })
      if (!listing) return { outcome: 'notFound' } as const

      const feeBps = await this.feeBpsNow(tx)
      const money = priceOf(
        toBaseUnits(listing.unitPrice.toFixed(0)),
        listing.quantity,
        feeBps,
      )

      // ตรวจก่อนเขียนอะไรต่อ · ยอดที่หน้าจอถือไว้ต้องตรง
      if (money.totalPrice !== expectedTotalPrice)
        return { outcome: 'conflict', code: 'PRICE_MISMATCH' } as const

      // ควรเป็นจริงเสมอจาก priceOf · เช็คไว้กันโค้ดในอนาคตแก้สูตรผิด
      if (!moneyBalances(money))
        throw new Error(`invariant: fee บวก net ไม่เท่ากับ total · ${JSON.stringify(money)}`)

      const operationId = ('op_' + short()) as OperationId
      const purchaseId = ('pur_' + short()) as PurchaseId

      // ---- สร้าง operation · จุดที่ฐานข้อมูลตัดสินสิทธิ์ ------------------
      // trg_buy_admissible  รายการมีอยู่ · ACTIVE · คนซื้อไม่ใช่คนขาย
      // uq_listing_inflight รายการนี้ไม่มีงานค้าง (ซื้อหรือถอด)
      try {
        await tx.operation.create({
          data: {
            id: operationId,
            actorScope: scope,
            kind: 'LISTING_BUY',
            status: 'PENDING',
            subjectId: listingId,
            payload: { listingId, totalPrice: money.totalPrice } as Prisma.InputJsonValue,
          },
        })
      } catch (e) {
        if (isUnique(e)) return { outcome: 'conflict', code: 'LISTING_BUSY' } as const
        if (isCheck(e)) return classifyAdmitError(e)
        throw e
      }

      // ---- กันเงิน · ไม่ใช่ย้ายเงิน --------------------------------------
      // trg_thb_reservation_balance ล็อกบัญชีด้วย advisory lock
      // แล้วเทียบ amount กับ f_available_thb
      // ยอดไม่พอ = 23514 · ไม่มีทางอื่น ไม่มี autoMint (F4)
      const buyerAccount = ledgerAccountOf(buyer.kind)
      try {
        await tx.reservation.create({
          data: {
            id: 'rsv_' + short(),
            operationId,
            subjectType: 'THB_BALANCE',
            subjectId: accountKey(buyerAccount, buyer.id),
            amount: money.totalPrice,
          },
        })
      } catch (e) {
        if (isCheck(e) && messageOf(e).includes('ยอด THB ไม่พอ'))
          return { outcome: 'conflict', code: 'INSUFFICIENT_THB' } as const
        throw e
      }

      // ---- บันทึกการซื้อ · ราคาคัดลอกมาตอนนี้ ไม่อ่านย้อนหลัง ---------------
      // trg_purchase_math ตรวจเลขสามทางอีกชั้น
      await tx.purchase.create({
        data: {
          id: purchaseId,
          listingId,
          buyerKind: buyer.kind,
          buyerId: buyer.id,
          sellerKind: listing.sellerKind,
          sellerId: listing.sellerId,
          unitPrice: listing.unitPrice,
          quantity: listing.quantity,
          totalPrice: money.totalPrice,
          feeBps: money.feeBps,
          feeAmount: money.feeAmount,
          netToSeller: money.netToSeller,
          status: 'PENDING',
          operationId,
        },
      })

      await tx.operationStep.createMany({
        data: BUY_STEPS.map((name, i) => ({
          id: 'st_' + short(),
          operationId,
          stepIndex: i + 1,
          name,
        })),
      })

      await tx.outbox.create({
        data: {
          id: 'obx_' + short(),
          operationId,
          topic: 'listing.buy.v1',
          payload: { listingId, purchaseId } as Prisma.InputJsonValue,
        },
      })

      await tx.operationEvent.create({
        data: { id: 'oev_' + short(), operationId, toStatus: 'PENDING', actor: 'CUSTOMER' },
      })

      const body = {
        purchaseId,
        listingId,
        totalPrice: money.totalPrice,
        feeBps: money.feeBps,
        feeAmount: money.feeAmount,
        netToSeller: money.netToSeller,
        status: 'PENDING' as const,
        operationId,
        stepCount: BUY_STEPS.length,
      }
      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 202, responseBody: body },
      })

      return { outcome: 'accepted', purchaseId, operationId, money }
    })
  }

  /**
   * เงินและของย้ายแล้ว · indexer เรียกเมื่อเห็น event ของ executePurchase
   *
   * ลำดับในนี้ไม่ใช่เรื่องของความถูกต้อง เพราะ trigger ทั้งสองตัว
   * เป็น DEFERRED · ตรวจตอน COMMIT ครั้งเดียว ไม่สนว่าเขียนอะไรก่อนหลัง
   * ซึ่งเป็นสิ่งที่ต้องการ · ชุดของ ledger ที่สมดุลมีความหมายเป็นชุด
   * ไม่ใช่เป็นแถว จึงไม่มีลำดับไหนที่ "ถูก" กว่าลำดับอื่น
   */
  async settle(
    purchaseId: PurchaseId,
    chainEventId: string,
  ): Promise<{ moved: bigint; codes: number }> {
    return this.db.$transaction(async (tx) => {
      const p = await tx.purchase.findUnique({
        where: { id: purchaseId },
        include: { listing: { include: { items: true } } },
      })
      if (!p) throw new Error(`ไม่พบการซื้อ ${purchaseId}`)
      if (p.status !== 'PENDING') throw new Error(`การซื้อ ${purchaseId} ไม่ใช่ PENDING`)

      const money: Money = {
        totalPrice: toBaseUnits(p.totalPrice.toFixed(0)),
        feeBps: p.feeBps,
        feeAmount: toBaseUnits(p.feeAmount.toFixed(0)),
        netToSeller: toBaseUnits(p.netToSeller.toFixed(0)),
      }

      const lines = purchaseLedger(
        money,
        { account: ledgerAccountOf(p.buyerKind), id: p.buyerId },
        { account: ledgerAccountOf(p.sellerKind), id: p.sellerId },
        PLATFORM_ACCOUNT_ID,
      )

      // ตรวจก่อนส่งไปฐานข้อมูล · ฐานข้อมูลตรวจซ้ำตอน COMMIT อีกที
      // สองชั้นเพราะชั้นนี้ให้ข้อความที่ดีกว่า ชั้นนั้นกันได้จริงกว่า
      if (!ledgerBalances(lines))
        throw new Error('invariant: ledger ไม่สมดุล · ไม่ส่งต่อให้ฐานข้อมูล')

      await tx.ledgerEntry.createMany({
        data: lines.map((l, i) => ({
          id: 'le_' + short(),
          operationId: p.operationId,
          entrySeq: i + 1,
          account: l.account,
          accountId: l.accountId,
          amount: l.amount.toString(),
          memo: l.memo,
        })),
      })

      // ยอดคงเหลือ · upsert ทีละบัญชี
      for (const l of lines) await this.applyToBalance(tx, l)

      await tx.purchase.update({
        where: { id: purchaseId },
        data: { status: 'SETTLED', settledAt: new Date() },
      })
      await tx.operation.update({
        where: { id: p.operationId },
        data: { status: 'FINALIZED', finalizedAt: new Date() },
      })
      await tx.listing.update({
        where: { id: p.listingId },
        data: { status: 'SOLD' },
      })

      // คูปองย้ายไปผู้ซื้อ · ทุกแถวอ้าง chain_event ที่ทำให้มันเกิด
      const items = p.listing.items as { couponCodeId: string }[]
      for (const it of items) {
        await tx.$executeRaw`
          INSERT INTO coupon_holding (coupon_code_id, holder_kind, holder_id, chain_event_id)
          VALUES (${it.couponCodeId}, ${p.buyerKind}::holder_kind, ${p.buyerId}, ${chainEventId})
          ON CONFLICT (coupon_code_id) DO UPDATE
            SET holder_kind = EXCLUDED.holder_kind,
                holder_id   = EXCLUDED.holder_id,
                chain_event_id = EXCLUDED.chain_event_id,
                applied_at  = now()`
        await tx.couponCode.update({
          where: { id: it.couponCodeId },
          data: { holderKind: p.buyerKind, holderId: p.buyerId },
        })
      }

      // ปล่อยการจองทั้งฝั่งเงินและฝั่งคูปอง
      await tx.$executeRaw`
        UPDATE reservation SET released_at = now()
         WHERE released_at IS NULL
           AND operation_id IN (
             SELECT id FROM operation
              WHERE subject_id = ${p.listingId}
                AND kind IN ('LISTING_CREATE','LISTING_BUY'))`

      return { moved: BigInt(money.totalPrice), codes: items.length }
    })
  }

  /**
   * tx revert · ปล่อยเงินที่กันไว้คืน
   *
   * ไม่มี ledger entry เลย เพราะไม่มีเงินเคลื่อนไปไหน
   * นี่คือเหตุผลที่ admit() กันเงินแทนที่จะย้ายเงิน — ทางกู้คืนว่างเปล่า
   * ทางกู้คืนที่ว่างเปล่าคือทางกู้คืนที่ไม่พัง
   */
  async markFailed(purchaseId: PurchaseId, note: string): Promise<void> {
    await this.db.$transaction(async (tx) => {
      const p = await tx.purchase.findUnique({ where: { id: purchaseId } })
      if (!p) throw new Error(`ไม่พบการซื้อ ${purchaseId}`)

      await tx.operation.update({
        where: { id: p.operationId },
        data: { status: 'CHAIN_REVERTED', errorNote: note },
      })
      // ต้องหลัง operation เป็น CHAIN_REVERTED · trg_reservation_release_timing
      await tx.$executeRaw`
        UPDATE reservation SET released_at = now()
         WHERE operation_id = ${p.operationId} AND released_at IS NULL`
      await tx.purchase.update({
        where: { id: purchaseId },
        data: { status: 'FAILED' },
      })
      await tx.operationEvent.create({
        data: {
          id: 'oev_' + short(),
          operationId: p.operationId,
          fromStatus: 'SUBMITTED',
          toStatus: 'CHAIN_REVERTED',
          metadata: { note } as Prisma.InputJsonValue,
        },
      })
    })
  }

  /** ยอดคงเหลือ · ที่กันไว้ · ที่ใช้ได้ */
  async balance(kind: HolderKind, id: string) {
    const account = ledgerAccountOf(kind)
    const key = accountKey(account, id)
    const rows = (await this.db.$queryRaw`
      SELECT coalesce((SELECT amount FROM thb_balance
                        WHERE account = ${account}::ledger_account
                          AND account_id = ${key}), 0)::text AS amount,
             f_reserved_thb(${key})::text                    AS reserved,
             f_available_thb(${account}::ledger_account, ${key})::text AS available
    `) as { amount: string; reserved: string; available: string }[]
    const r = rows[0]
    if (!r) throw new Error('invariant: query ยอดคงเหลือไม่คืนแถว')
    return {
      asset: 'THB' as const,
      amount: toBaseUnits(r.amount),
      reserved: toBaseUnits(r.reserved),
      available: toBaseUnits(r.available),
    }
  }

  // ------------------------------------------------------------ internal
  private async feeBpsNow(tx: {
    $queryRaw(s: TemplateStringsArray, ...v: unknown[]): Promise<unknown[]>
  }): Promise<number> {
    const rows = (await tx.$queryRaw`SELECT f_fee_bps_at(now()) AS bps`) as
      { bps: number | null }[]
    const bps = rows[0]?.bps
    if (bps === null || bps === undefined)
      throw new Error('ไม่มีอัตราค่าธรรมเนียมที่มีผล · fee_schedule ว่าง')
    return Number(bps)
  }

  private async applyToBalance(
    tx: { $executeRaw(s: TemplateStringsArray, ...v: unknown[]): Promise<number> },
    l: LedgerLine,
  ): Promise<void> {
    await tx.$executeRaw`
      INSERT INTO thb_balance (account, account_id, amount)
      VALUES (${l.account}::ledger_account, ${l.accountId}, ${l.amount.toString()}::numeric)
      ON CONFLICT (account, account_id) DO UPDATE
        SET amount = thb_balance.amount + ${l.amount.toString()}::numeric,
            updated_at = now()`
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
 * แปลงข้อความจาก trg_buy_admissible เป็นคำตอบของ API
 * ข้อความถูกเขียนเป็นภาษาไทยในฐานข้อมูลไว้แล้ว จึงจับคำที่แยกกรณีได้
 */
function classifyAdmitError(e: unknown): BuyResult {
  const m = messageOf(e)
  if (m.includes('ไม่พบรายการขาย')) return { outcome: 'notFound' }
  if (m.includes('ของตัวเอง'))     return { outcome: 'conflict', code: 'SELF_PURCHASE' }
  if (m.includes('ซื้อไม่ได้'))      return { outcome: 'conflict', code: 'LISTING_NOT_ACTIVE' }
  if (m.includes('ยอด THB ไม่พอ')) return { outcome: 'conflict', code: 'INSUFFICIENT_THB' }
  return { outcome: 'notFound' }
}
