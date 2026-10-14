/**
 * FEAT-04 · ชั้น ADMIT ของการสร้าง point type
 *
 * สองเรื่องที่ feature นี้ต่างจากชุดก่อน
 *   1 · ไม่มีการเรียก external อะไรก่อน BEGIN เลย · ทุกอย่างอยู่ใน transaction เดียว
 *   2 · ความซ้ำของชื่อและ symbol ตัดสินด้วย unique index ไม่ใช่ SELECT มาเช็คก่อน
 *       เพราะ SELECT แล้วค่อย INSERT มีช่องว่างให้ request อื่นแทรก
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  AdmitResult, CreatePointTypeRequest, MerchantId, PointTypeId, OperationId,
} from './types'
import { SYMBOL_RE, MAX_DECIMALS } from './types'
import { createHash, randomUUID } from 'node:crypto'

/** sha256 ของ DTO ที่ normalize แล้ว · ห้ามใส่ salt/secret/HMAC (RFD 3 L7) */
export function fingerprint(dto: unknown): Buffer {
  const canonical = JSON.stringify(dto, Object.keys(dto as object).sort())
  return createHash('sha256').update(canonical.normalize('NFC')).digest()
}

export class ValidationError extends Error {
  constructor(readonly field: string, msg: string) {
    super(msg)
  }
}

export class PointTypeService {
  constructor(private readonly db: PrismaClient) {}

  async create(
    merchantId: MerchantId,
    idempotencyKey: string,
    dto: CreatePointTypeRequest,
  ): Promise<AdmitResult> {
    // ---- validate ก่อนแตะฐานข้อมูล ------------------------------------
    const name = dto.name.normalize('NFC').trim()
    const symbol = dto.symbol.trim()
    if (name.length < 1 || name.length > 60)
      throw new ValidationError('name', 'ชื่อต้องยาว 1-60 ตัวอักษร')
    if (!SYMBOL_RE.test(symbol))
      throw new ValidationError('symbol', 'symbol ต้องเป็นตัวพิมพ์ใหญ่ 2-11 ตัว')
    if (!Number.isInteger(dto.decimals) || dto.decimals < 0 || dto.decimals > MAX_DECIMALS)
      throw new ValidationError('decimals', `decimals ต้องอยู่ในช่วง 0-${MAX_DECIMALS}`)

    const scope = `merchant:${merchantId}`
    const fp = fingerprint({ name, symbol, decimals: dto.decimals })

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

      const pointTypeId = ('pt_' + short()) as PointTypeId
      const operationId = ('op_' + short()) as OperationId

      // ---- ไม่ SELECT มาเช็คชื่อซ้ำก่อน --------------------------------
      // ระหว่าง SELECT กับ INSERT มีช่องว่างให้ request อื่นแทรกเข้ามาได้เสมอ
      // ปล่อยให้ unique index เป็นตัวตัดสิน แล้วแปลง error เป็น 409
      //
      // trigger trg_point_type_merchant_active จะ raise ถ้าร้านยังไม่ ACTIVE
      // จึงไม่ต้องเช็คสถานะร้านเองที่นี่
      try {
        await tx.pointType.create({
          data: {
            id: pointTypeId,
            merchantId,
            name,
            symbol,
            decimals: dto.decimals,
            status: 'REQUESTED',
          },
        })
      } catch (e) {
        const code = constraintOf(e)
        if (code === 'uq_point_symbol') return { outcome: 'conflict', code: 'SYMBOL_TAKEN' } as const
        if (code === 'uq_point_name') return { outcome: 'conflict', code: 'NAME_TAKEN' } as const
        throw e
      }

      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: scope,
          kind: 'POINT_TYPE_CREATE',
          status: 'PENDING',
          subjectId: pointTypeId,
          payload: { pointTypeId, name, symbol, decimals: dto.decimals } as Prisma.InputJsonValue,
        },
      })

      // deploy เป็น tx เดียว · ไม่เหมือน FEAT-01 ที่มีสองขั้น
      await tx.operationStep.create({
        data: { id: 'st_' + short(), operationId, stepIndex: 1, name: 'createPointToken' },
      })

      // commit พร้อม operation เสมอ (RFD 2 D1)
      await tx.outbox.create({
        data: {
          id: 'obx_' + short(),
          operationId,
          topic: 'point.type.create.v1',
          payload: { pointTypeId } as Prisma.InputJsonValue,
        },
      })

      await tx.operationEvent.create({
        data: { id: 'oev_' + short(), operationId, toStatus: 'PENDING', actor: 'MERCHANT_ADMIN' },
      })

      const body = {
        pointTypeId,
        name,
        symbol,
        decimals: dto.decimals,
        status: 'REQUESTED' as const,
        operationId,
      }

      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 202, responseBody: body },
      })

      return { outcome: 'created', pointTypeId, operationId }
    })
  }
}

/**
 * ฝั่ง projector — เขียน point_type_chain จาก chain_event
 * แยกไว้ให้เห็นว่าใครเขียนตารางไหน (RFD 6)
 *
 * ค่าที่เขียนลงตารางนี้ต้อง derive จาก event ล้วนๆ
 * ห้ามอ่านค่าจาก point_type มาใส่ ไม่งั้น rebuild แล้วจะได้คนละค่า
 */
export interface PointTokenCreatedEvent {
  pointTypeId: PointTypeId
  contractAddress: Buffer
  blockNumber: bigint
  txHash: Buffer
  genesisAt: Date
  epochSeconds: number
  validityEpochs: number
}

export class PointTypeProjector {
  constructor(private readonly db: PrismaClient) {}

  async apply(ev: PointTokenCreatedEvent): Promise<void> {
    await this.db.$transaction(async (tx) => {
      await tx.pointTypeChain.create({
        data: {
          pointTypeId: ev.pointTypeId,
          contractAddress: ev.contractAddress,
          deployedBlock: ev.blockNumber,
          deployedTxHash: ev.txHash,
          genesisAt: ev.genesisAt,
          epochSeconds: ev.epochSeconds,
          validityEpochs: ev.validityEpochs,
        },
      })
      // สถานะฝั่งร้านเปลี่ยนเป็น LIVE ได้ก็ต่อเมื่อแถวฝั่ง chain มีแล้ว
      // invariant T15 ตรวจข้อนี้
      await tx.pointType.update({
        where: { id: ev.pointTypeId },
        data: { status: 'LIVE', liveAt: new Date() },
      })
    })
  }

  /** deploy ล้ม · ปล่อยชื่อและ symbol คืนให้ใช้ใหม่ได้ */
  async markFailed(pointTypeId: PointTypeId, note: string): Promise<void> {
    await this.db.pointType.update({
      where: { id: pointTypeId },
      data: { status: 'FAILED' },
    })
    void note
  }
}

function short(): string {
  return randomUUID().replace(/-/g, '').slice(0, 12)
}

/** ดึงชื่อ constraint ออกจาก error ของ Postgres เพื่อแยกว่าชนที่ index ไหน */
function constraintOf(e: unknown): string | undefined {
  const meta = (e as { meta?: { target?: unknown } }).meta
  const t = meta?.target
  if (typeof t === 'string') return t
  if (Array.isArray(t) && typeof t[0] === 'string') return t[0]
  return undefined
}
