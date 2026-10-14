/**
 * FEAT-01 · ชั้น ADMIT ของการสมัครร้านค้า
 *
 * ลำดับในฟังก์ชันนี้คือสิ่งที่ห้ามสลับ
 *   RFD 3 R1 · INSERT idempotency_key เป็นสเตตเมนต์แรกของ transaction
 *   RFD 4 D3 · เรียก KMS ให้จบก่อน BEGIN · ห้ามถือ transaction คร่อม external call
 *   RFD 8 §3.4 · คืน 201 ไม่ใช่ 202 · provision เป็นงานแยกที่ commit พร้อมกัน
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  AdmitResult, CreateMerchantRequest, Kms, MerchantId, AdminId, OperationId, Address,
} from './types'
import { normalizeEmail } from './types'
import { createHash, randomUUID } from 'node:crypto'

/** sha256 ของ DTO ที่ normalize แล้ว · ห้ามใส่ salt/secret/HMAC (RFD 3 L7) */
export function fingerprint(dto: unknown): Buffer {
  const canonical = JSON.stringify(dto, Object.keys(dto as object).sort())
  return createHash('sha256').update(canonical.normalize('NFC')).digest()
}

/** scope ตอนสมัคร · ยังไม่มี actor จึงผูกกับอีเมลที่ normalize แล้ว */
export function anonScope(email: string): `anon:${string}` {
  return `anon:${createHash('sha256').update(normalizeEmail(email)).digest('hex')}`
}

export interface PasswordHasher {
  /** ต้องคืน PHC string ที่ขึ้นต้น $argon2id$ · CHECK ใน DB บังคับไว้ */
  hash(plain: string): Promise<string>
}

export class OnboardingService {
  constructor(
    private readonly db: PrismaClient,
    private readonly kms: Kms,
    private readonly hasher: PasswordHasher,
  ) {}

  async createMerchant(
    idempotencyKey: string,
    dto: CreateMerchantRequest,
  ): Promise<AdmitResult> {
    // ---- 1 · normalize ก่อนทุกอย่าง -----------------------------------
    // สูตรเดียวกันนี้ต้องใช้ทั้งตอนเก็บ ตอนค้นหา และตอนทำ scope
    const emailNormalized = normalizeEmail(dto.admin.email)
    const scope = anonScope(dto.admin.email)
    const fp = fingerprint({ ...dto, admin: { ...dto.admin, email: emailNormalized } })

    // ---- 2 · งานหนักที่ไม่ต้องอยู่ใน transaction ------------------------
    // argon2id กินเวลาหลักร้อย ms · KMS เป็น network call
    // ทั้งคู่ทำก่อน BEGIN เพื่อไม่ให้ transaction ถือ lock ค้างระหว่างรอ
    const passwordHash = await this.hasher.hash(dto.admin.password)
    const key = await this.kms.createKey(`merchant:${emailNormalized}`)
    // ถ้าพังหลังจากบรรทัดนี้ จะเหลือ key กำพร้าใน KMS
    // ยอมรับได้ · key ที่ไม่มีใครใช้ไม่ทำให้ระบบผิด ตรงข้ามกับร้านที่ไม่มี key

    // ---- 3 · ADMIT · ทุกแถวหรือไม่มีเลย -------------------------------
    return this.db.$transaction(async (tx) => {
      // R1 · สเตตเมนต์แรกเสมอ · ON CONFLICT DO NOTHING แล้วนับแถว
      // ห้าม try/catch เพราะสเตตเมนต์ที่ error ทำให้ transaction aborted (25P02)
      const inserted = await tx.$executeRaw`
        INSERT INTO idempotency_key (id, scope, key, fingerprint, expires_at)
        VALUES (${'ik_' + randomUUID()}, ${scope}, ${idempotencyKey},
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

      const merchantId = ('mch_' + short()) as MerchantId
      const adminId = ('adm_' + short()) as AdminId
      const operationId = ('op_' + short()) as OperationId

      await tx.merchant.create({
        data: { id: merchantId, name: dto.name.trim(), status: 'PENDING' },
      })

      // uq_admin_email อยู่บน email_normalized · อีเมลซ้ำจะชนที่นี่
      // ปล่อยให้ unique violation ขึ้นมาแล้วแปลงเป็น 409 EMAIL_TAKEN ที่ชั้นบน
      await tx.merchantAdmin.create({
        data: {
          id: adminId,
          merchantId,
          email: dto.admin.email.trim(),
          emailNormalized,
          passwordHash,
          displayName: dto.admin.displayName.trim(),
        },
      })

      // RFD 4 L6 · เก็บได้แค่ address กับ key_ref
      await tx.wallet.create({
        data: {
          id: 'wal_' + short(),
          address: hexToBytes(key.address),
          keyRef: key.keyRef,
          ownerKind: 'MERCHANT',
          ownerId: merchantId,
        },
      })

      // งาน provision บน chain · uq_provision_inflight กันสั่งซ้อนบนร้านเดิม
      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: scope,
          kind: 'MERCHANT_PROVISION',
          status: 'PENDING',
          subjectId: merchantId,
          payload: { merchantId, address: key.address } as Prisma.InputJsonValue,
        },
      })

      await tx.operationStep.createMany({
        data: [
          { id: 'st_' + short(), operationId, stepIndex: 1, name: 'whitelistMerchant' },
          { id: 'st_' + short(), operationId, stepIndex: 2, name: 'setApprovalForAll' },
        ],
      })

      // commit พร้อม operation เสมอ · งานจึงหายไม่ได้ (RFD 2 D1)
      await tx.outbox.create({
        data: {
          id: 'obx_' + short(),
          operationId,
          topic: 'merchant.provision.v1',   // ต้องมีเวอร์ชันต่อท้าย
          payload: { merchantId } as Prisma.InputJsonValue,
        },
      })

      await tx.operationEvent.create({
        data: { id: 'oev_' + short(), operationId, toStatus: 'PENDING', actor: 'SYSTEM' },
      })

      const body = {
        merchantId,
        name: dto.name.trim(),
        status: 'PENDING' as const,
        admin: { adminId, email: dto.admin.email.trim() },
        wallet: { address: key.address, ready: false },
        provisioning: { operationId, status: 'PENDING' as const },
      }

      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { operationId, responseStatus: 201, responseBody: body },
      })

      return { outcome: 'created', merchantId, operationId }
    })
    // หลัง COMMIT: ยิง queue ให้ worker รู้เร็วขึ้น
    // ยิงไม่สำเร็จไม่เป็นไร · worker เจอแถวใน outbox เองในรอบถัดไป
  }
}

function short(): string {
  return randomUUID().replace(/-/g, '').slice(0, 12)
}

function hexToBytes(a: Address): Buffer {
  return Buffer.from(a.slice(2), 'hex')
}

/**
 * ร้านยังใช้ความสามารถบน chain ไม่ได้จนกว่า provision จะ FINALIZED
 * เรียกตัวนี้ที่ guard ของทุก endpoint ที่ต้องยิง tx
 */
export function assertWalletReady(status: string): void {
  if (status !== 'ACTIVE') {
    const e = new Error('ร้านยังเตรียม wallet ไม่เสร็จ')
    ;(e as Error & { code: string }).code = 'MERCHANT_WALLET_NOT_READY'
    throw e
  }
}
