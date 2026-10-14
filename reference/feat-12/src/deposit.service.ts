/**
 * FEAT-12 · การฝากเงิน การ mint และการตีกลับ
 *
 * สิ่งที่ feature นี้ต่างจากชุดก่อน
 *   1 · idempotency มาจากข้างนอก · ผู้ให้บริการชำระเงินเลือกคีย์ ไม่ใช่เรา
 *   2 · ตรวจลายเซ็นจาก body ดิบ ก่อน parse
 *   3 · การ mint ไม่ใช่การตัดสินใจของเรา · เป็นผลของการที่เงินบาทเข้ามาแล้ว
 *   4 · บางกรณีจบที่ MANUAL_REVIEW และนั่นคือคำตอบที่ถูก ไม่ใช่การยอมแพ้
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  BaseUnits, DepositId, DepositResult, HolderKind, LedgerLine,
  MintResult, OperationId, PspEvent, Satang, WebhookResult,
} from './types'
import {
  MINT_STEPS, accountKey, burnLedger, isAmountInRange, isMintable,
  isReversible, ledgerAccountOf, ledgerBalances, mintLedger,
  reversalOutcomeFor, satangToBase, toBaseUnits, toSatang,
} from './types'
import { createHash, randomUUID, timingSafeEqual, createHmac } from 'node:crypto'

/**
 * ตรวจลายเซ็น webhook ด้วย HMAC
 *
 * ข้อควรระวังที่อ่านผิดกันบ่อย
 *   L7 / SPEC-001 [IK-23] ห้ามใช้ salt / secret / HMAC
 *   แต่ข้อนั้นพูดถึง fingerprint ของ idempotency key เท่านั้น
 *   เพราะ fingerprint ต้องคำนวณซ้ำได้จากคำขอเดียวกันโดยไม่ต้องรู้ความลับใด
 *
 *   ลายเซ็น webhook เป็นงานตรงข้าม · ต้องพิสูจน์ว่าผู้ส่งรู้ความลับ
 *   HMAC คือเครื่องมือที่ถูกต้องสำหรับงานนี้
 *   อ่าน [IK-23] กว้างเกินจะได้ webhook ที่ไม่ตรวจอะไรเลย
 *
 * เทียบด้วย timingSafeEqual · การเทียบ string ธรรมดารั่วข้อมูลผ่านเวลา
 */
export function verifySignature(
  rawBody: Buffer,
  signature: string,
  secret: string,
): boolean {
  const expected = createHmac('sha256', secret).update(rawBody).digest('hex')
  const a = Buffer.from(expected, 'utf8')
  const b = Buffer.from(signature, 'utf8')
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

/** SPEC-001 [IK-23] · hash ตรงๆ · ไม่มี salt ไม่มี secret */
export function fingerprint(body: unknown): Buffer {
  return createHash('sha256')
    .update(JSON.stringify(body).normalize('NFC'))
    .digest()
}

export class DepositService {
  constructor(
    private readonly db: PrismaClient,
    private readonly secrets: Readonly<Record<string, string>>,
  ) {}

  // ===================================================== 1 · สร้างรายการฝาก
  async create(
    scope: string,
    holder: { kind: HolderKind; id: string },
    idempotencyKey: string,
    provider: string,
    amountSatang: Satang,
  ): Promise<DepositResult> {
    if (!isAmountInRange(amountSatang))
      return { outcome: 'rejected', code: 'AMOUNT_OUT_OF_RANGE' }

    const fp = fingerprint({ provider, amountSatang })
    const amountBase = satangToBase(amountSatang)

    return this.db.$transaction(async (tx) => {
      // ---- R1 · สเตตเมนต์แรกของ transaction เสมอ ----------------------
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
          return { outcome: 'rejected', code: 'IDEMPOTENCY_KEY_REUSED' } as const
        if (prior.responseStatus === null)
          return { outcome: 'rejected', code: 'IDEMPOTENCY_KEY_IN_PROGRESS' } as const
        return { outcome: 'replayed', status: prior.responseStatus, body: prior.responseBody }
      }

      const depositId = ('dep_' + short()) as DepositId

      // trg_deposit_amount_exact ตรวจว่าสองหน่วยแปลงกันพอดี
      // ไม่เชื่อ satangToBase ฝ่ายเดียว · ฐานข้อมูลคำนวณเองแล้วเทียบ
      await tx.thbDeposit.create({
        data: {
          id: depositId,
          holderKind: holder.kind,
          holderId: holder.id,
          provider,
          // reference ที่ส่งให้ผู้ให้บริการ · เขาจะส่งกลับมาใน webhook
          providerRef: depositId,
          amountSatang: BigInt(amountSatang),
          amountBase,
          status: 'PENDING_PAYMENT',
          expiresAt: new Date(Date.now() + 24 * 3600 * 1000),
        },
      })

      const body = {
        depositId,
        amountSatang,
        amountBase,
        status: 'PENDING_PAYMENT' as const,
      }
      await tx.idempotencyKey.update({
        where: { scope_key: { scope, key: idempotencyKey } },
        data: { responseStatus: 201, responseBody: body },
      })

      return { outcome: 'created', depositId, amountBase }
    })
  }

  // ================================================== 2 · รับ webhook
  /**
   * ลำดับในนี้สำคัญ
   *   1 ตรวจลายเซ็นจาก body ดิบ · parse แล้ว serialize ใหม่จะได้ byte คนละชุด
   *   2 บันทึกแถว psp_webhook ทั้งที่ลายเซ็นไม่ผ่าน
   *     เพื่อให้เห็นว่ามีคนยิงเข้ามา · ix_psp_unprocessed กรองออกจากคิวเอง
   *   3 ถ้าลายเซ็นผ่าน จึงประมวลผล
   *
   * ข้อ 2 สำคัญกว่าที่คิด · webhook ที่ลายเซ็นไม่ผ่านคือข้อมูลด้านความปลอดภัย
   * ทิ้งไปเงียบๆ แปลว่ามีคนลองยิงเข้ามาแล้วไม่มีใครรู้
   */
  async receiveWebhook(
    provider: string,
    rawBody: Buffer,
    signature: string,
  ): Promise<WebhookResult> {
    const secret = this.secrets[provider]
    if (secret === undefined) throw new Error(`ไม่มี secret ของผู้ให้บริการ ${provider}`)

    const ok = verifySignature(rawBody, signature, secret)

    let evt: PspEvent
    try {
      evt = JSON.parse(rawBody.toString('utf8')) as PspEvent
    } catch {
      // parse ไม่ได้ · ยังบันทึกไว้ แต่ไม่มี event id ให้กันซ้ำ
      await this.db.pspWebhook.create({
        data: {
          id: 'wh_' + short(),
          provider,
          providerEventId: 'unparseable_' + short(),
          eventType: 'unknown',
          rawBody,
          signature,
          signatureOk: ok,
        },
      })
      return { outcome: 'badSignature' }
    }

    // provider_event_id เป็น UNIQUE · นี่คือ idempotency ตัวจริงของ feature นี้
    const written = await this.db.$executeRaw`
      INSERT INTO psp_webhook (id, provider, provider_event_id, event_type,
                               raw_body, signature, signature_ok)
      VALUES (${'wh_' + short()}, ${provider}, ${evt.id}, ${evt.type},
              ${rawBody}, ${signature}, ${ok})
      ON CONFLICT (provider, provider_event_id) DO NOTHING`

    if (written === 0) return { outcome: 'duplicate' }
    if (!ok) return { outcome: 'badSignature' }

    const row = await this.db.pspWebhook.findFirst({
      where: { provider, providerEventId: evt.id },
    })
    if (!row) throw new Error('invariant: เขียน webhook แล้วหาไม่เจอ')

    switch (evt.type) {
      case 'charge.complete':
        return this.confirmDeposit(provider, evt, row.id as string)
      case 'charge.failed':
        return this.failDeposit(provider, evt, row.id as string)
      case 'charge.reverse':
        return this.reverseDeposit(provider, evt, row.id as string)
    }
  }

  /**
   * เงินเข้าแล้ว · ยืนยันการฝาก
   *
   * ยอดที่ webhook แจ้งต้องตรงกับที่บันทึกไว้ · ไม่ตรงคือสัญญาณว่ามีอะไรผิด
   * ไม่ใช่สัญญาณให้แก้ยอดตาม · การยืนยันแล้วแก้ยอดถูกปิดที่ฐานข้อมูลอยู่แล้ว
   */
  private async confirmDeposit(
    provider: string,
    evt: PspEvent,
    webhookId: string,
  ): Promise<WebhookResult> {
    return this.db.$transaction(async (tx) => {
      const dep = await tx.thbDeposit.findFirst({
        where: { provider, providerRef: evt.data.reference },
      })
      if (!dep) {
        await tx.pspWebhook.update({
          where: { id: webhookId }, data: { processedAt: new Date() },
        })
        return { outcome: 'accepted', depositId: null, action: 'ไม่พบการฝากที่ตรงกับ reference' }
      }

      if (String(dep.amountSatang) !== evt.data.amountSatang) {
        // ไม่แก้ยอดตาม · บันทึกว่าไม่ตรงแล้วรอคนตรวจ
        await tx.pspWebhook.update({
          where: { id: webhookId }, data: { processedAt: new Date() },
        })
        return {
          outcome: 'accepted',
          depositId: dep.id as DepositId,
          action: `ยอดไม่ตรง · แจ้ง ${evt.data.amountSatang} บันทึกไว้ ${dep.amountSatang}`,
        }
      }

      await tx.thbDeposit.update({
        where: { id: dep.id },
        data: { status: 'CONFIRMED', webhookId },
      })
      await tx.pspWebhook.update({
        where: { id: webhookId }, data: { processedAt: new Date() },
      })
      return { outcome: 'accepted', depositId: dep.id as DepositId, action: 'ยืนยันแล้ว · พร้อม mint' }
    })
  }

  private async failDeposit(
    provider: string,
    evt: PspEvent,
    webhookId: string,
  ): Promise<WebhookResult> {
    return this.db.$transaction(async (tx) => {
      const dep = await tx.thbDeposit.findFirst({
        where: { provider, providerRef: evt.data.reference },
      })
      if (dep && dep.status === 'PENDING_PAYMENT') {
        await tx.thbDeposit.update({ where: { id: dep.id }, data: { status: 'FAILED' } })
      }
      await tx.pspWebhook.update({
        where: { id: webhookId }, data: { processedAt: new Date() },
      })
      return {
        outcome: 'accepted',
        depositId: (dep?.id ?? null) as DepositId | null,
        action: 'จ่ายไม่สำเร็จ · ไม่มี THB เกิดขึ้น',
      }
    })
  }

  // ================================================== 3 · สั่ง mint
  /**
   * สร้างงาน mint · ไม่ได้ mint เองที่นี่
   *
   * ที่นี่ไม่ตรวจว่าการฝาก CONFIRMED แล้วหรือยังด้วย SELECT ก่อน
   * ปล่อยให้ trg_mint_requires_confirmed_deposit ตัดสินตอน INSERT
   * เหตุผลเดียวกับทุก pack · เช็คก่อนแล้วเขียนคือสองสเตตเมนต์
   * และช่องว่างระหว่างสองสเตตเมนต์คือที่ที่ F1 อยู่
   */
  async queueMint(depositId: DepositId): Promise<MintResult> {
    return this.db.$transaction(async (tx) => {
      const dep = await tx.thbDeposit.findUnique({ where: { id: depositId } })
      if (!dep) return { outcome: 'rejected', code: 'DEPOSIT_NOT_FOUND' } as const

      const operationId = ('op_' + short()) as OperationId
      const account = ledgerAccountOf(dep.holderKind as HolderKind)
      const key = accountKey(account, dep.holderId as string)

      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: 'system:minter',
          kind: 'THB_MINT',
          status: 'PENDING',
          subjectId: depositId,
          payload: {
            depositId,
            amountBase: dep.amountBase.toFixed(0),
          } as Prisma.InputJsonValue,
        },
      })

      // trigger ตัดสินที่สเตตเมนต์นี้ · สามข้อในครั้งเดียว
      try {
        await tx.thbMint.create({
          data: {
            depositId,
            operationId,
            amountBase: dep.amountBase,
            toAccount: account,
            toAccountId: key,
          },
        })
      } catch (e) {
        if (isUnique(e)) return { outcome: 'rejected', code: 'DEPOSIT_ALREADY_MINTED' } as const
        if (isCheck(e)) {
          const m = messageOf(e)
          if (m.includes('ไม่เท่ากับยอดที่ฝาก'))
            return { outcome: 'rejected', code: 'AMOUNT_MISMATCH' } as const
          return { outcome: 'rejected', code: 'DEPOSIT_NOT_CONFIRMED' } as const
        }
        throw e
      }

      await tx.operationStep.createMany({
        data: MINT_STEPS.map((name, i) => ({
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
          topic: 'thb.mint.v1',
          payload: { depositId } as Prisma.InputJsonValue,
        },
      })

      return { outcome: 'queued', operationId }
    })
  }

  /**
   * THB เกิดขึ้นบน chain แล้ว · indexer เรียก
   *
   * สองแถว ledger รวมได้ศูนย์ · ปลายทาง +amount และ ISSUANCE −amount
   * F4 คือการเขียนแค่แถวแรก และ trg_ledger_balanced ไม่ยอม commit ให้
   */
  async applyMint(
    depositId: DepositId,
    chain: { chainEventId: string; txHash: Buffer; block: bigint },
  ): Promise<{ minted: bigint }> {
    return this.db.$transaction(async (tx) => {
      const mint = await tx.thbMint.findUnique({ where: { depositId } })
      if (!mint) throw new Error(`ไม่พบงาน mint ของการฝาก ${depositId}`)

      const amount = toBaseUnits(mint.amountBase.toFixed(0))
      const lines = mintLedger(amount, {
        account: mint.toAccount as never,
        // to_account_id เก็บเป็น 'ACCOUNT:id' อยู่แล้ว · เอาส่วนหลังมา
        id: String(mint.toAccountId).split(':')[1] ?? '',
      })
      if (!ledgerBalances(lines))
        throw new Error('invariant: ledger ของการ mint ไม่สมดุล')

      await tx.thbMint.update({
        where: { depositId },
        data: {
          chainEventId: chain.chainEventId,
          txHash: chain.txHash,
          mintedBlock: chain.block,
          appliedAt: new Date(),
        },
      })

      await tx.ledgerEntry.createMany({
        data: lines.map((l, i) => ({
          id: 'le_' + short(),
          operationId: mint.operationId,
          entrySeq: i + 1,
          account: l.account,
          accountId: l.accountId,
          amount: l.amount.toString(),
          memo: l.memo,
        })),
      })
      for (const l of lines) await this.applyToBalance(tx, l)

      await tx.operation.update({
        where: { id: mint.operationId },
        data: { status: 'FINALIZED', finalizedAt: new Date() },
      })
      await tx.thbDeposit.update({
        where: { id: depositId },
        data: { status: 'MINTED' },
      })

      return { minted: BigInt(amount) }
    })
  }

  // ================================================== 4 · การตีกลับ
  /**
   * เงินบาทถูกตีกลับ แต่ THB ถูก mint ไปแล้ว และอาจถูกใช้ไปแล้ว
   *
   * ยอดที่ใช้ได้ยังพอ → เผาคืน · ledger สมดุล · จบ
   * ยอดไม่พอ        → MANUAL_REVIEW · ไม่แตะยอด ไม่แต่งตัวเลข
   *
   * ผลลัพธ์ไม่ใช่สิ่งที่โค้ดเลือก · คำนวณจากยอดที่มีจริง
   * และ trg_reversal_outcome_matches_balance ปฏิเสธถ้าไม่ตรง ทั้งสองทิศทาง
   * ทำให้ "เลือกทางที่สะดวกกว่า" เป็นไปไม่ได้
   */
  private async reverseDeposit(
    provider: string,
    evt: PspEvent,
    webhookId: string,
  ): Promise<WebhookResult> {
    return this.db.$transaction(async (tx) => {
      const dep = await tx.thbDeposit.findFirst({
        where: { provider, providerRef: evt.data.reference },
      })
      await tx.pspWebhook.update({
        where: { id: webhookId }, data: { processedAt: new Date() },
      })
      if (!dep) return { outcome: 'accepted', depositId: null, action: 'ไม่พบการฝาก' }

      // ยังไม่ mint · ไม่มี THB ออกไป ไม่มีอะไรต้องเผา
      if (!isReversible(dep.status as never)) {
        if (dep.status === 'PENDING_PAYMENT') {
          await tx.thbDeposit.update({ where: { id: dep.id }, data: { status: 'FAILED' } })
        }
        return {
          outcome: 'accepted',
          depositId: dep.id as DepositId,
          action: `สถานะ ${dep.status} · ไม่มี THB ที่ต้องเผา`,
        }
      }

      const account = ledgerAccountOf(dep.holderKind as HolderKind)
      const key = accountKey(account, dep.holderId as string)
      const amount = toBaseUnits(dep.amountBase.toFixed(0))

      const rows = (await tx.$queryRaw`
        SELECT f_available_thb(${account}::ledger_account, ${key})::text AS avail
      `) as { avail: string }[]
      const available = toBaseUnits(rows[0]?.avail ?? '0')

      const outcome = reversalOutcomeFor(amount, available)
      const operationId = ('op_' + short()) as OperationId

      await tx.operation.create({
        data: {
          id: operationId,
          actorScope: 'system:psp',
          kind: 'THB_MINT',
          status: 'FINALIZED',
          subjectId: dep.id,
          payload: { depositId: dep.id, reversal: true } as Prisma.InputJsonValue,
          finalizedAt: new Date(),
        },
      })

      await tx.depositReversal.create({
        data: {
          id: 'rev_' + short(),
          depositId: dep.id,
          webhookId,
          operationId,
          amountBase: amount,
          availableAtReversal: available,
          outcome,
          note: outcome === 'MANUAL_REVIEW'
            ? 'ยอดที่ใช้ได้ไม่พอเผาคืน · THB ถูกใช้ไปแล้ว'
            : null,
        },
      })

      if (outcome === 'BURNED') {
        const lines = burnLedger(amount, { account, id: dep.holderId as string })
        if (!ledgerBalances(lines))
          throw new Error('invariant: ledger ของการเผาไม่สมดุล')
        await tx.ledgerEntry.createMany({
          data: lines.map((l, i) => ({
            id: 'le_' + short(),
            operationId,
            entrySeq: i + 1,
            account: l.account,
            accountId: l.accountId,
            amount: l.amount.toString(),
            memo: l.memo,
          })),
        })
        for (const l of lines) await this.applyToBalance(tx, l)
      }

      await tx.thbDeposit.update({ where: { id: dep.id }, data: { status: 'REVERSED' } })

      return {
        outcome: 'accepted',
        depositId: dep.id as DepositId,
        action: outcome === 'BURNED' ? 'เผา THB คืนแล้ว' : 'ยอดไม่พอ · รอคนตรวจ',
      }
    })
  }

  // ------------------------------------------------------------ อ่าน
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

  /** หารายการที่ยืนยันแล้วแต่ยังไม่ mint · worker เรียกเป็นรอบ */
  async pendingMints(limit = 20): Promise<DepositId[]> {
    const rows = await this.db.thbDeposit.findMany({
      where: { status: 'CONFIRMED' },
      orderBy: { confirmedAt: 'asc' },
      take: limit,
    })
    return (rows as { id: string }[]).map((r) => r.id as DepositId)
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

/** ช่วยอ่าน · ใช้ในหน้าจอแอดมิน */
export function describeSatang(s: Satang): string {
  return `${formatThousands(BigInt(s) / 100n)}.${(BigInt(s) % 100n).toString().padStart(2, '0')} บาท`
}

function formatThousands(v: bigint): string {
  return v.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

export { toSatang, satangToBase }
