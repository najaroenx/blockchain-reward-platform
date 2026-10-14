/**
 * FEAT-02 · ขอ OTP · ยืนยัน · สมัคร
 *
 * สามข้อที่ชั้นนี้ไม่ทำ และตั้งใจไม่ทำ
 *   1 ไม่คืนค่า OTP ให้ใครเลย แม้แต่ใน log  (F6)
 *   2 ไม่รับเบอร์โทรในขั้นยืนยัน             (F7)
 *   3 ไม่เคยถือ private key                (F10 · F13 · L6)
 *
 * และข้อที่ชั้นนี้ไม่ตัดสิน
 *   การนับครั้งที่ลองและการล็อก อยู่ใน f_verify_otp ของฐานข้อมูล
 *   เพราะต้องเกิดใน transaction เดียวกับการล็อกแถว
 *   แยกเป็นหลายคำสั่งจะมีช่องให้ยิงขนานแล้วได้ลองเกินจำนวนครั้ง
 *   ซึ่งเป็นเรื่องเดียวกับ F1
 */
import type { PrismaClient, Prisma } from '@prisma/client'
import type {
  AttemptResult, ChallengeId, CustomerId, MeView, OperationId,
  OtpChallengeAccepted, PhoneE164, VerifyOtpResult,
} from './types'
import {
  MAX_ATTEMPTS, OTP_LENGTH, OTP_TTL_SECONDS, attemptsLeft,
  isOtpFormat, isPhoneE164, maskPhone, normalizePhone,
} from './types'
import { createHash, createHmac, randomBytes, randomInt, randomUUID } from 'node:crypto'

export class PhoneInvalid extends Error {
  constructor(raw: string) {
    // ไม่ใส่เบอร์ดิบลงข้อความ · ข้อความ error ไปอยู่ใน log
    super(`เบอร์โทรไม่ใช่รูปที่รู้จัก (ความยาว ${raw.length})`)
  }
}

export class OtpRejected extends Error {
  constructor(readonly result: AttemptResult, readonly attemptsLeft: number) {
    super(`ยืนยัน OTP ไม่ผ่าน · ${result}`)
  }
}

export interface Sms {
  send(to: PhoneE164, text: string): Promise<void>
}

export interface Kms {
  /** pepper สำหรับ hash OTP · ไม่เคยถูกเก็บในฐานข้อมูล */
  pepper(ref: string): Promise<string>
  /** สร้าง key ใหม่แล้วคืน address กับ ref · key ไม่ออกจาก KMS (L6) */
  createWallet(ownerId: string): Promise<{ address: Buffer; keyRef: string }>
}

export class RegisterService {
  constructor(
    private readonly db: PrismaClient,
    private readonly sms: Sms,
    private readonly kms: Kms,
    private readonly pepperRef = 'kms://otp-pepper/v1',
  ) {}

  // =============================================== ขอ OTP
  /**
   * F6 · คืน challengeId เท่านั้น · OTP ไปทาง SMS
   *
   * ค่าที่คืนเหมือนกันทุกกรณี ไม่ว่าเบอร์จะสมัครแล้วหรือยัง
   * ถ้าตอบต่างกัน endpoint นี้จะกลายเป็นเครื่องมือตรวจว่าเบอร์ไหน
   * เป็นลูกค้าของเรา และใครก็ไล่เบอร์ทั้งประเทศได้
   *
   * OTP อยู่ในตัวแปรท้องถิ่นช่วงสั้นที่สุดที่เป็นไปได้
   * ไม่เข้า log ไม่เข้า response ไม่เข้าฐานข้อมูล
   */
  async requestOtp(rawPhone: string): Promise<OtpChallengeAccepted> {
    const phone = normalizePhone(rawPhone)
    if (phone === null) throw new PhoneInvalid(rawPhone)

    const challengeId = ('ch_' + short()) as ChallengeId
    const code = generateOtp()
    const pepper = await this.kms.pepper(this.pepperRef)
    const codeHash = hashOtp(pepper, challengeId, code)
    const expiresAt = new Date(Date.now() + OTP_TTL_SECONDS * 1000)

    await this.db.$transaction(async (tx) => {
      // challenge เดิมที่ยังค้างถือว่าหมดอายุทันที
      // ขอใหม่ = อันเก่าใช้ไม่ได้ · ไม่ใช่มีสองอันใช้ได้พร้อมกัน
      await tx.$executeRaw`
        UPDATE otp_challenge SET status = 'EXPIRED'
         WHERE phone_e164 = ${phone} AND status = 'PENDING'`

      // trg_throttle_check ปฏิเสธถ้าขอถี่เกินไปหรือเบอร์ถูกล็อก
      await tx.$executeRaw`
        INSERT INTO otp_challenge (id, phone_e164, code_hash, pepper_ref,
                                   max_attempts, expires_at)
        VALUES (${challengeId}, ${phone}, ${codeHash}, ${this.pepperRef},
                ${MAX_ATTEMPTS}, ${expiresAt})`

      await tx.$executeRaw`
        INSERT INTO phone_throttle (phone_e164, sent_count, last_sent_at)
        VALUES (${phone}, 1, now())
        ON CONFLICT (phone_e164) DO UPDATE
          SET sent_count = CASE
                WHEN phone_throttle.window_start + interval '1 hour' <= now()
                THEN 1 ELSE phone_throttle.sent_count + 1 END,
              window_start = CASE
                WHEN phone_throttle.window_start + interval '1 hour' <= now()
                THEN now() ELSE phone_throttle.window_start END,
              last_sent_at = now()`
    })

    // ส่งหลัง commit · ส่งก่อนแล้ว transaction ล้ม ลูกค้าได้รหัสที่ใช้ไม่ได้
    await this.sms.send(phone, `รหัสยืนยันของคุณคือ ${code} (หมดอายุใน 5 นาที)`)

    return {
      challengeId,
      expiresAt: expiresAt.toISOString(),
      attemptsAllowed: MAX_ATTEMPTS,
      // ไม่มีช่อง code และจะไม่มี · F6
    }
  }

  // =============================================== ยืนยันและสมัคร
  /**
   * F7 · ไม่รับเบอร์โทรเป็น parameter เลย
   * เบอร์มาจาก challenge ที่ server สร้างไว้เอง
   *
   * F12 · ยืนยันสำเร็จแล้วได้ session ทันที ไม่ใช่คืน 201 เปล่า
   */
  async verifyAndRegister(
    challengeId: ChallengeId,
    code: string,
    displayName?: string,
  ): Promise<VerifyOtpResult> {
    if (!isOtpFormat(code)) throw new OtpRejected('WRONG_CODE', MAX_ATTEMPTS)

    const pepper = await this.kms.pepper(this.pepperRef)

    // ฐานข้อมูลตัดสินผล · นับครั้ง ล็อกแถว และล็อกเบอร์ ในสเตตเมนต์เดียว
    const rows = (await this.db.$queryRaw`
      SELECT f_verify_otp(${challengeId}, ${code}, ${pepper})::text AS result
    `) as { result: AttemptResult }[]
    const result = rows[0]?.result
    if (!result) throw new Error('f_verify_otp ไม่คืนค่า')

    if (result !== 'OK') {
      const st = (await this.db.$queryRaw`
        SELECT attempts, max_attempts FROM otp_challenge WHERE id = ${challengeId}
      `) as { attempts: number; max_attempts: number }[]
      const a = st[0]
      throw new OtpRejected(result, a ? attemptsLeft(a.attempts, a.max_attempts) : 0)
    }

    const ch = (await this.db.$queryRaw`
      SELECT phone_e164, verified_at FROM otp_challenge WHERE id = ${challengeId}
    `) as { phone_e164: string; verified_at: Date }[]
    const row = ch[0]
    if (!row || !isPhoneE164(row.phone_e164))
      throw new Error('challenge ที่ยืนยันแล้วไม่มีเบอร์ที่ถูกรูป')
    const phone = row.phone_e164

    return this.db.$transaction(async (tx) => {
      const existing = (await tx.$queryRaw`
        SELECT id, status FROM customer WHERE phone_e164 = ${phone}
      `) as { id: string; status: string }[]

      let customerId: CustomerId
      let isNew = false
      let operationId: OperationId | null = null

      if (existing[0]) {
        customerId = existing[0].id as CustomerId
      } else {
        isNew = true
        customerId = ('cus_' + short()) as CustomerId

        // trg_customer_phone_from_challenge อ่าน setting นี้
        // และปฏิเสธถ้าเบอร์ไม่ตรงกับ challenge · F7
        await tx.$executeRaw`SELECT set_config('app.verified_challenge', ${challengeId}, true)`

        await tx.$executeRaw`
          INSERT INTO customer (id, phone_e164, display_name, phone_verified_at)
          VALUES (${customerId}, ${phone}, ${displayName ?? null}, ${row.verified_at})`

        operationId = ('op_' + short()) as OperationId
        await tx.$executeRaw`
          INSERT INTO operation (id, actor_scope, kind, subject_id, payload)
          VALUES (${operationId}, ${'customer:' + customerId},
                  'CUSTOMER_PROVISION', ${customerId},
                  ${JSON.stringify({ customerId })}::jsonb)`
        await tx.$executeRaw`
          INSERT INTO operation_step (id, operation_id, step_index, name)
          VALUES (${'st_' + short()}, ${operationId}, 1, 'provisionWallet')`
        await tx.$executeRaw`
          INSERT INTO outbox (id, operation_id, topic, payload)
          VALUES (${'obx_' + short()}, ${operationId}, 'customer.provision.v1',
                  ${JSON.stringify({ customerId })}::jsonb)`
      }

      // challenge ใช้ได้ครั้งเดียว
      await tx.$executeRaw`
        UPDATE otp_challenge SET status = 'CONSUMED' WHERE id = ${challengeId}`

      // F12 · ได้ token ทันที · ฐานข้อมูลเก็บแต่ hash
      const token = randomBytes(32).toString('base64url')
      const expires = new Date(Date.now() + 30 * 24 * 3600 * 1000)
      await tx.$executeRaw`
        INSERT INTO customer_session (id, customer_id, token_hash, expires_at)
        VALUES (${'ses_' + short()}, ${customerId},
                ${createHash('sha256').update(token).digest()}, ${expires})`

      const status = (await tx.$queryRaw`
        SELECT status FROM customer WHERE id = ${customerId}
      `) as { status: string }[]

      return {
        customerId,
        phone,
        customerStatus: (status[0]?.status ?? 'PENDING_WALLET') as never,
        isNewCustomer: isNew,
        accessToken: token,
        expiresAt: expires.toISOString(),
        operationId,
      }
    })
  }

  /**
   * wallet ขึ้น chain แล้ว · worker เรียก
   *
   * L6 · KMS สร้าง key และเก็บไว้เอง · เราได้แค่ address กับ ref
   * ไม่มีจุดไหนในฟังก์ชันนี้ที่ key ผ่านมือเรา
   */
  async provisionWallet(customerId: CustomerId): Promise<{ address: string }> {
    const { address, keyRef } = await this.kms.createWallet(customerId)
    await this.db.$transaction(async (tx) => {
      await tx.$executeRaw`
        INSERT INTO wallet (address, owner_kind, owner_id, kms_key_ref, status, live_at)
        VALUES (${address}, 'CUSTOMER', ${customerId}, ${keyRef}, 'LIVE', now())`
      await tx.$executeRaw`
        UPDATE customer SET status = 'ACTIVE' WHERE id = ${customerId}`
    })
    return { address: '0x' + address.toString('hex') }
  }

  async me(customerId: CustomerId): Promise<MeView | null> {
    const rows = (await this.db.$queryRaw`
      SELECT c.id, c.phone_e164, c.display_name, c.status,
             encode(w.address, 'hex') AS addr
        FROM customer c
        LEFT JOIN wallet w ON w.owner_kind = 'CUSTOMER' AND w.owner_id = c.id
                          AND w.status = 'LIVE'
       WHERE c.id = ${customerId}
    `) as {
      id: string; phone_e164: string; display_name: string | null
      status: string; addr: string | null
    }[]
    const r = rows[0]
    if (!r) return null
    if (!isPhoneE164(r.phone_e164)) throw new Error('เบอร์ในฐานข้อมูลไม่ถูกรูป')
    return {
      customerId: r.id as CustomerId,
      phone: r.phone_e164,
      displayName: r.display_name,
      customerStatus: r.status as never,
      walletAddress: r.addr ? (('0x' + r.addr) as `0x${string}`) : null,
      // ไม่มีช่องใดในนี้ที่เกี่ยวกับ key · F10 F13 L6
    }
  }

  /** เอาไว้แสดงใน log และหน้าแอดมิน · ไม่แสดงเบอร์เต็ม */
  static describe(phone: PhoneE164): string {
    return maskPhone(phone)
  }
}

/**
 * OTP · randomInt ของ node ใช้ CSPRNG
 * Math.random ใช้ไม่ได้เด็ดขาด · มันเดาได้จากผลก่อนหน้า
 */
function generateOtp(): string {
  const max = 10 ** OTP_LENGTH
  return String(randomInt(0, max)).padStart(OTP_LENGTH, '0')
}

/**
 * hash ของ OTP · ตรงกับที่ f_verify_otp คำนวณ
 *
 * ใช้ HMAC กับ pepper ที่อยู่ใน KMS ไม่ใช่ sha256 เปล่า
 * OTP หกหลักมีความเป็นไปได้แค่ล้านแบบ · sha256 ของทั้งล้านแบบ
 * คำนวณเสร็จในเสี้ยววินาที ใครได้ฐานข้อมูลไปก็ย้อนหาได้ทุกแถว
 *
 * L7 / [IK-23] ห้าม HMAC เฉพาะกับ fingerprint ของ idempotency key
 * เพราะอันนั้นต้องคำนวณซ้ำได้โดยไม่รู้ความลับ · อันนี้ต้องคำนวณไม่ได้
 */
export function hashOtp(pepper: string, challengeId: string, code: string): Buffer {
  return createHmac('sha256', pepper).update(`${challengeId}:${code}`).digest()
}

function short(): string {
  return randomUUID().replace(/-/g, '').slice(0, 12)
}
