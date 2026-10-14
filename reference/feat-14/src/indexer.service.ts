/**
 * FEAT-14 · indexer และ projector
 *
 * ชั้นนี้บางโดยตั้งใจ · มันทำสองอย่างเท่านั้น
 *   1 คุย RPC แล้วเอาข้อมูลลงฐานข้อมูล
 *   2 เรียกฟังก์ชันของฐานข้อมูลที่ถือตรรกะจริงไว้
 *
 * ตรรกะการแปลง event เป็น projection ไม่อยู่ที่นี่ และห้ามย้ายมา
 * เพราะ f_replay_projections ต้องใช้ตรรกะเดียวกับการ apply ครั้งแรก
 * ถ้าตรรกะอยู่ในไฟล์นี้ การ replay จะต้องรันไฟล์รุ่นเดียวกับตอนนั้น
 * ซึ่งเป็นไปไม่ได้เมื่อ deploy ใหม่
 */
import type { PrismaClient } from '@prisma/client'
import type {
  BlockHeader, EventPosition, Hash32, IndexerStatus, ReorgId,
} from './types'
import { findForkPoint, isInChainOrder, reorgDepth } from './types'

/** key ของ advisory lock · คงที่ เพราะมี indexer ตัวเดียวเท่านั้น */
const INDEXER_LOCK_KEY = 0x1de7e7n

export interface ChainRpc {
  head(): Promise<bigint>
  block(n: bigint): Promise<{
    number: bigint
    hash: Hash32
    parentHash: Hash32
    timestamp: Date
    txCount: number
  }>
  logs(from: bigint, to: bigint): Promise<{
    blockNumber: bigint
    blockHash: Hash32
    txHash: Hash32
    logIndex: number
    address: Hash32
    topics: Hash32[]
    data: string
  }[]>
}

export class IndexerService {
  constructor(
    private readonly db: PrismaClient,
    private readonly rpc: ChainRpc,
    private readonly owner: string,
  ) {}

  // =============================================== L8 · instance เดียว
  /**
   * ขอสิทธิ์เป็น indexer
   *
   * สองชั้นที่ใช้ร่วมกัน และทั้งสองจำเป็น
   *   advisory lock  กันสอง process ที่ยังมีชีวิตพร้อมกัน
   *                  หายไปเองเมื่อ connection ตาย ซึ่งเป็นสิ่งที่ต้องการ
   *   lease          กัน process ที่ยังไม่ตายแต่หยุดตอบสนอง
   *                  advisory lock ดักไม่ได้เพราะ connection ยังอยู่
   *
   * ชั้นเดียวไม่พอ · lock เดี่ยวปล่อยให้ process ที่แฮงค์ถือไปตลอด
   * lease เดี่ยวปล่อยให้สอง process ที่เร็วพอๆ กันแย่งกันขยับ
   */
  async acquire(leaseSeconds = 30): Promise<boolean> {
    const got = (await this.db.$queryRaw`
      SELECT pg_try_advisory_lock(${INDEXER_LOCK_KEY}::bigint) AS ok
    `) as { ok: boolean }[]
    if (!got[0]?.ok) return false

    const n = await this.db.$executeRaw`
      UPDATE indexer_cursor
         SET lease_owner = ${this.owner},
             lease_until = now() + (${leaseSeconds} || ' seconds')::interval,
             updated_at = now()
       WHERE id = 'main'
         AND (lease_owner IS NULL OR lease_owner = ${this.owner}
              OR lease_until <= now())`
    if (n === 0) {
      await this.db.$executeRaw`SELECT pg_advisory_unlock(${INDEXER_LOCK_KEY}::bigint)`
      return false
    }
    return true
  }

  async release(): Promise<void> {
    await this.db.$executeRaw`
      UPDATE indexer_cursor SET lease_owner = NULL, lease_until = NULL
       WHERE id = 'main' AND lease_owner = ${this.owner}`
    await this.db.$executeRaw`SELECT pg_advisory_unlock(${INDEXER_LOCK_KEY}::bigint)`
  }

  // =============================================== อ่านบล็อกถัดไป
  /**
   * อ่านหนึ่งบล็อกแล้วขยับ cursor ใน transaction เดียว
   *
   * L8 ข้อสอง · ไม่แยกเป็นสอง transaction
   * trg_event_within_cursor ปฏิเสธถ้าแยก และนั่นคือสิ่งที่ควรเกิด
   * ไม่ใช่เพราะเป็นกฎ แต่เพราะ indexer ที่ restart ระหว่างสอง transaction
   * จะอ่านช่วงนั้นใหม่แล้วสถานะสับสน
   */
  async readNext(): Promise<{ block: bigint; events: number } | null> {
    const cur = await this.db.indexerCursor.findUnique({ where: { id: 'main' } })
    if (!cur) throw new Error('ไม่มีแถว indexer_cursor · ต้องสร้างก่อนเริ่มอ่าน')

    const next = BigInt(cur.lastBlock as bigint) + 1n
    const head = await this.rpc.head()
    if (next > head) return null

    const blk = await this.rpc.block(next)

    // ตรวจสายโซ่ก่อนเขียน · ฐานข้อมูลตรวจซ้ำอยู่แล้ว
    // ที่นี่ตรวจเพื่อแยกแยะว่าเป็น reorg แล้วไปเส้นทางจัดการ reorg
    // ไม่ใช่ปล่อยให้ INSERT ระเบิดแล้วตีความ error
    const lastHash = cur.lastBlockHash as Buffer | null
    if (lastHash && blk.parentHash !== ('0x' + lastHash.toString('hex'))) {
      const forkAt = await this.findFork(next)
      await this.handleReorg(forkAt)
      return { block: forkAt, events: 0 }
    }

    const logs = await this.rpc.logs(next, next)

    return this.db.$transaction(async (tx) => {
      await tx.$executeRaw`
        INSERT INTO raw_block (block_hash, block_number, parent_hash, timestamp, tx_count)
        VALUES (decode(${blk.hash.slice(2)}, 'hex'), ${blk.number},
                decode(${blk.parentHash.slice(2)}, 'hex'), ${blk.timestamp}, ${blk.txCount})`

      for (const l of logs) {
        const dec = decodeLog(l.topics, l.data)
        await tx.$executeRaw`
          INSERT INTO chain_event (id, block_number, block_hash, tx_hash, log_index,
                                   address, topic0, topics, data, block_timestamp,
                                   event_name, args)
          VALUES (${'ce_' + l.txHash.slice(2, 14) + '_' + l.logIndex},
                  ${l.blockNumber}, decode(${l.blockHash.slice(2)}, 'hex'),
                  decode(${l.txHash.slice(2)}, 'hex'), ${l.logIndex},
                  decode(${l.address.slice(2)}, 'hex'),
                  decode(${l.topics[0]?.slice(2) ?? ''}, 'hex'),
                  ${JSON.stringify(l.topics)}::jsonb,
                  decode(${l.data.slice(2)}, 'hex'), ${blk.timestamp},
                  ${dec.name}::chain_event_name,
                  ${dec.args === null ? null : JSON.stringify(dec.args)}::jsonb)
          ON CONFLICT (tx_hash, log_index) DO NOTHING`
      }

      // ขยับ cursor ใน transaction เดียวกัน · L8
      await tx.$executeRaw`
        UPDATE indexer_cursor
           SET last_block = ${blk.number},
               last_block_hash = decode(${blk.hash.slice(2)}, 'hex'),
               updated_at = now()
         WHERE id = 'main'`

      return { block: blk.number, events: logs.length }
    })
  }

  /**
   * หาจุดที่สายแยก · เดินย้อนจนเจอบล็อกที่ hash ตรงกับ chain
   *
   * RFD 5 · เทียบ hash ไม่ใช่นับความลึก
   * สายที่ยาวกว่าอาจเป็นสายอื่น · ความลึกบอกอะไรไม่ได้เลยในขั้นนี้
   */
  private async findFork(from: bigint): Promise<bigint> {
    let n = from - 1n
    const floor = n > 200n ? n - 200n : 1n
    while (n >= floor) {
      const ours = (await this.db.$queryRaw`
        SELECT encode(block_hash, 'hex') AS h FROM raw_block
         WHERE block_number = ${n} AND orphaned_at IS NULL
      `) as { h: string }[]
      const mine = ours[0]?.h
      if (!mine) return n + 1n

      const theirs = await this.rpc.block(n)
      if (theirs.hash === '0x' + mine) return n + 1n
      n -= 1n
    }
    throw new Error(`หาจุดแยกไม่ได้ในช่วง 200 บล็อก · reorg ลึกเกินกว่าจะจัดการเอง`)
  }

  /**
   * จัดการ reorg · เรียกฟังก์ชันของฐานข้อมูล
   *
   * ไม่ย้อนทีละ event แบบย้อนกลับ เพราะ event บางชนิดย้อนไม่ได้ตรงๆ
   * CouponRedeemed ลบแถวใน coupon_holding · จะรู้ได้อย่างไรว่าเดิมใครถือ
   *
   * จึง orphan แล้ว replay ทั้งหมดใหม่ · ช้ากว่า แต่ถูกเสมอ
   * และใช้ตรรกะเดียวกับ apply ปกติ แปลว่าไม่มีโค้ดเส้นที่สองที่ต้องดูแล
   */
  async handleReorg(forkBlock: bigint): Promise<ReorgId> {
    const rows = (await this.db.$queryRaw`
      SELECT f_handle_reorg(${forkBlock}, ${this.owner}) AS id
    `) as { id: string }[]
    const id = rows[0]?.id
    if (!id) throw new Error('f_handle_reorg ไม่คืนค่า')
    return id as ReorgId
  }

  // =============================================== projector
  /** apply ตามลำดับ (block_number, log_index) · ฐานข้อมูลเรียงให้ */
  async applyPending(limit = 1000): Promise<number> {
    const rows = (await this.db.$queryRaw`
      SELECT f_apply_pending(${limit}) AS n
    `) as { n: number }[]
    return Number(rows[0]?.n ?? 0)
  }

  /** ทำเครื่องหมายว่าลึกพอแล้ว · เรียกหลังขยับ cursor */
  async markFinalized(): Promise<number> {
    const rows = (await this.db.$queryRaw`SELECT f_mark_finalized() AS n`) as
      { n: number }[]
    return Number(rows[0]?.n ?? 0)
  }

  /**
   * RFD 6 §3.2 · ลบ projection แล้วสร้างใหม่จาก chain_event
   *
   * ข้อควรรู้ก่อนเรียก · ถ้าตรรกะใน f_apply_event เปลี่ยนไปจากตอนที่
   * apply ครั้งแรก ผลที่ได้จะเป็นค่าตามตรรกะวันนี้ ไม่ใช่ค่าเดิม
   * ซึ่งมักเป็นสิ่งที่ต้องการ แต่ไม่ใช่ทุกครั้ง
   */
  async replayProjections(): Promise<{ applied: number; durationMs: number }> {
    const t0 = Date.now()
    const rows = (await this.db.$queryRaw`
      SELECT f_replay_projections() AS n
    `) as { n: number }[]
    return { applied: Number(rows[0]?.n ?? 0), durationMs: Date.now() - t0 }
  }

  // =============================================== สถานะ
  async status(): Promise<IndexerStatus> {
    const head = await this.rpc.head()
    const rows = (await this.db.$queryRaw`
      SELECT c.last_block::text                         AS last_block,
             encode(c.last_block_hash, 'hex')           AS last_hash,
             c.lease_owner                              AS lease_owner,
             c.lease_until                              AS lease_until,
             f_finality_depth(now())                    AS depth,
             (SELECT count(*) FROM chain_event
               WHERE applied_at IS NULL AND orphaned_at IS NULL)::int AS pending
        FROM indexer_cursor c WHERE c.id = 'main'
    `) as {
      last_block: string; last_hash: string | null
      lease_owner: string | null; lease_until: Date | null
      depth: number; pending: number
    }[]
    const r = rows[0]
    if (!r) throw new Error('ไม่มีแถว indexer_cursor')

    const last = Number(r.last_block)
    return {
      lastBlock: last,
      lastBlockHash: r.last_hash ? (('0x' + r.last_hash) as Hash32) : null,
      chainHead: Number(head),
      lagBlocks: Number(head) - last,
      leaseHeldBy: r.lease_owner,
      leaseUntil: r.lease_until ? r.lease_until.toISOString() : null,
      finalityDepth: Number(r.depth),
      pendingEvents: r.pending,
    }
  }

  /** ตรวจว่าคิวที่อ่านมาเรียงตามลำดับบน chain · ใช้ใน test และ assert */
  static checkOrder(events: readonly EventPosition[]): boolean {
    return isInChainOrder(events)
  }

  /** หาจุดแยกจากชุด header ที่อ่านมา · ใช้ใน test */
  static forkPointOf(chain: readonly BlockHeader[]): bigint | null {
    return findForkPoint(chain)
  }

  static depthOf(forkBlock: bigint, oldTip: bigint): number {
    return reorgDepth(forkBlock, oldTip)
  }
}

/**
 * ถอดรหัส log เป็นชนิดและ args
 *
 * ของจริงใช้ ABI · ที่นี่เป็นโครงที่แสดงว่า topic0 เป็นตัวแยกชนิด
 * และ args ที่ได้เป็นแคชของการถอดรหัส ไม่ใช่แหล่งความจริง
 * data ในฐานข้อมูลคือของจริง และถอดรหัสใหม่ได้เสมอ
 */
export function decodeLog(
  topics: readonly string[],
  _data: string,
): { name: string; args: Record<string, unknown> | null } {
  const t0 = topics[0]
  if (!t0) return { name: 'UNKNOWN', args: null }
  // ของจริงเทียบกับ keccak256 ของ signature ใน ABI
  return { name: 'UNKNOWN', args: null }
}
