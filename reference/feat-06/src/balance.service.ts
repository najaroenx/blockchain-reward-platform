/**
 * FEAT-06 · ฝั่งอ่านยอด point
 *
 * กฎของไฟล์นี้
 *   1 · ไม่เรียก new Date() ข้างใน method · เวลามาจากพารามิเตอร์ asOf เสมอ
 *   2 · ไม่คำนวณยอดใน TypeScript · เรียกฟังก์ชัน SQL ตัวเดียวกับที่ trigger
 *       ของ FEAT-05 ใช้ จะได้ไม่มีสองสูตรที่ค่อยๆ ต่างกัน
 *   3 · ทุก response มี freshness · ผู้เรียกต้องรู้ว่า projection ตามหลังแค่ไหน
 */
import type { PrismaClient } from '@prisma/client'
import type {
  AsOf, BalanceView, BucketView, ForecastView, Freshness, HolderKind,
  NoticeRequest, NoticeView, PointTypeId, BaseUnits, BucketId, NoticeId,
} from './types'
import { toBaseUnits, subClamped, isThreshold } from './types'
import { randomUUID } from 'node:crypto'

export class NotFound extends Error {}
export class Conflict extends Error {}
export class Unprocessable extends Error {}

export class BalanceService {
  constructor(private readonly db: PrismaClient) {}

  // =================================================================
  // 1 · ยอดคงเหลือ
  // =================================================================
  async balanceOf(
    pointTypeId: PointTypeId,
    holderKind: HolderKind,
    holderId: string,
    asOf: AsOf,
    includeExpired = false,
  ): Promise<BalanceView> {
    const pt = await this.db.pointType.findUnique({ where: { id: pointTypeId } })
    if (!pt) throw new NotFound('ไม่พบ point type')

    // คำนวณในฐานข้อมูล ไม่ใช่ใน TypeScript
    // ฟังก์ชันพวกนี้เป็นตัวเดียวกับที่ trigger ของ FEAT-05 ใช้ตรวจตอนจอง
    const [agg] = (await this.db.$queryRaw`
      SELECT
        f_unexpired_total(${pointTypeId}, ${holderKind}::holder_kind, ${holderId}, ${asOf.at})::text AS unexpired,
        f_reserved_total (${pointTypeId}, ${holderKind}::holder_kind, ${holderId})::text            AS reserved
    `) as { unexpired: string; reserved: string }[]

    const unexpiredTotal = toBaseUnits(agg?.unexpired ?? '0')
    const reserved = toBaseUnits(agg?.reserved ?? '0')

    const rows = (await this.db.$queryRaw`
      SELECT id, amount::text AS amount, received_at, expires_at,
             (expires_at <= ${asOf.at}) AS expired
        FROM point_balance_bucket
       WHERE point_type_id = ${pointTypeId}
         AND holder_kind   = ${holderKind}::holder_kind
         AND holder_id     = ${holderId}
         AND amount > 0
         AND (${includeExpired} OR expires_at > ${asOf.at})
       ORDER BY expires_at, id
    `) as {
      id: string; amount: string; received_at: Date; expires_at: Date; expired: boolean
    }[]

    const buckets: BucketView[] = rows.map((r) => ({
      bucketId: r.id as BucketId,
      amount: toBaseUnits(r.amount),
      receivedAt: r.received_at.toISOString(),
      expiresAt: r.expires_at.toISOString(),
      expired: r.expired,
    }))

    return {
      pointTypeId,
      holderKind,
      holderId,
      decimals: pt.decimals,
      asOf: asOf.at.toISOString(),
      // ติดลบไม่ได้ · เกิดได้จริงเมื่อ bucket หมดอายุระหว่างที่ยังจองค้างอยู่
      available: subClamped(unexpiredTotal, reserved),
      reserved,
      unexpiredTotal,
      buckets,
      freshness: await this.freshness(),
    }
  }

  // =================================================================
  // 2 · พยากรณ์การหมดอายุ
  // =================================================================
  async forecast(
    pointTypeId: PointTypeId,
    holderKind: HolderKind,
    holderId: string,
    asOf: AsOf,
    horizonDays: number,
  ): Promise<ForecastView> {
    if (!Number.isInteger(horizonDays) || horizonDays < 1 || horizonDays > 730)
      throw new Unprocessable('horizonDays ต้องอยู่ในช่วง 1-730')

    const rows = (await this.db.$queryRaw`
      SELECT expires_on::text AS expires_on, amount::text AS amount
        FROM f_expiry_forecast(${pointTypeId}, ${holderKind}::holder_kind,
                               ${holderId}, ${asOf.at}, ${horizonDays})
    `) as { expires_on: string; amount: string }[]

    const days = rows.map((r) => ({
      expiresOn: r.expires_on,
      amount: toBaseUnits(r.amount),
    }))

    const total = days.reduce((a, d) => a + BigInt(d.amount), 0n)

    return {
      pointTypeId,
      asOf: asOf.at.toISOString(),
      horizonDays,
      totalExpiring: toBaseUnits(total),
      days,
    }
  }

  /** ยอดที่หมดอายุไปแล้วสะสม · เป็น query ไม่ใช่ตาราง */
  async expiredTotal(pointTypeId: PointTypeId, asOf: AsOf): Promise<BaseUnits> {
    const [r] = (await this.db.$queryRaw`
      SELECT f_expired_total(${pointTypeId}, ${asOf.at})::text AS v
    `) as { v: string }[]
    return toBaseUnits(r?.v ?? '0')
  }

  // =================================================================
  // 3 · บันทึกว่าแจ้งเตือนไปแล้ว
  // =================================================================
  /**
   * เรียกหลังส่งข้อความสำเร็จ · ไม่ใช่ตัวที่ส่งข้อความเอง
   *
   * ไม่เช็คเองว่าเคยส่งหรือยัง · ปล่อยให้ uq_notice เป็นตัวตัดสิน
   * ถ้าเช็คด้วย SELECT ก่อน จะมีช่องให้ job อีกตัวแทรกระหว่างทาง
   */
  async recordNotice(req: NoticeRequest): Promise<NoticeView> {
    if (!isThreshold(req.thresholdDays))
      throw new Unprocessable('thresholdDays ต้องเป็น 30, 7 หรือ 1')

    const id = ('en_' + randomUUID().replace(/-/g, '').slice(0, 12)) as NoticeId
    try {
      const row = await this.db.expiryNotice.create({
        data: {
          id,
          bucketId: req.bucketId,
          thresholdDays: req.thresholdDays,
          channel: req.channel,
        },
      })
      return {
        noticeId: id,
        bucketId: req.bucketId,
        thresholdDays: req.thresholdDays,
        channel: req.channel,
        notifiedAt: (row.notifiedAt as Date).toISOString(),
      }
    } catch (e) {
      if (isUnique(e)) throw new Conflict('เคยแจ้งเตือนที่ระดับนี้ไปแล้ว')
      // trigger trg_notice_not_expired คืน check_violation เมื่อ bucket หมดอายุแล้ว
      if (isCheck(e)) throw new Unprocessable('bucket หมดอายุไปแล้ว')
      throw e
    }
  }

  /**
   * หา bucket ที่ควรแจ้งเตือนที่ระดับหนึ่ง และยังไม่เคยแจ้ง
   * ไม่มี cron ที่ไล่ลดยอด · มีแค่ query นี้ที่ job เรียกเป็นรอบ
   */
  async dueForNotice(
    pointTypeId: PointTypeId,
    thresholdDays: number,
    asOf: AsOf,
    limit = 500,
  ): Promise<{ bucketId: BucketId; holderId: string; amount: BaseUnits; expiresAt: string }[]> {
    const rows = (await this.db.$queryRaw`
      SELECT b.id, b.holder_id, b.amount::text AS amount, b.expires_at
        FROM point_balance_bucket b
   LEFT JOIN expiry_notice n
          ON n.bucket_id = b.id AND n.threshold_days = ${thresholdDays}
       WHERE b.point_type_id = ${pointTypeId}
         AND b.amount > 0
         AND b.expires_at >  ${asOf.at}
         AND b.expires_at <= ${asOf.at} + make_interval(days => ${thresholdDays}::int)
         AND n.id IS NULL
       ORDER BY b.expires_at, b.id
       LIMIT ${limit}
    `) as { id: string; holder_id: string; amount: string; expires_at: Date }[]

    return rows.map((r) => ({
      bucketId: r.id as BucketId,
      holderId: r.holder_id,
      amount: toBaseUnits(r.amount),
      expiresAt: r.expires_at.toISOString(),
    }))
  }

  // =================================================================
  private async freshness(): Promise<Freshness> {
    const [r] = (await this.db.$queryRaw`
      SELECT w.last_block::text AS wm,
             COALESCE(max(c.last_block), w.last_block)::text AS head,
             EXTRACT(EPOCH FROM (now() - w.last_block_at))::int AS lag_seconds
        FROM projection_watermark w
   LEFT JOIN indexer_cursor c ON true
       GROUP BY w.last_block, w.last_block_at
    `) as { wm: string; head: string; lag_seconds: number }[]

    if (!r) return { asOfBlock: 0, lagBlocks: 0, lagSeconds: null }
    const wm = Number(r.wm)
    const head = Number(r.head)
    return {
      asOfBlock: wm,
      lagBlocks: Math.max(head - wm, 0),
      lagSeconds: r.lag_seconds ?? null,
    }
  }
}

function isUnique(e: unknown): boolean {
  const c = (e as { code?: string }).code
  return c === 'P2002' || c === '23505'
}

function isCheck(e: unknown): boolean {
  const c = (e as { code?: string }).code
  return c === '23514' || c === 'P2010'
}
