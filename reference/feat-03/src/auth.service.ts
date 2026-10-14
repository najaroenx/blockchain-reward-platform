/**
 * FEAT-03 · Auth · login และการหมุน refresh token
 *
 * สองจุดที่ห้ามลัด
 *   §1 · login ที่ล้มเหลวต้องใช้เวลาและข้อความเหมือนกันทุกกรณี
 *   §2 · การหมุน token ต้องอยู่ใน transaction เดียว และพึ่ง unique index
 *        เป็นตัวตัดสิน ไม่ใช่การ SELECT มาเช็คก่อน
 */
import type { PrismaClient } from '@prisma/client'
import type {
  LoginRequest, LoginResponse, RefreshOutcome, Subject,
  SessionId, FamilyId, AdminId, MerchantId, AccessClaims,
} from './types'
import {
  normalizeEmail, ACCESS_TTL_SECONDS, REFRESH_TTL_SECONDS,
  LOCKOUT_THRESHOLD, LOCKOUT_WINDOW_SECONDS,
} from './types'
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'

export interface PasswordHasher {
  hash(plain: string): Promise<string>
  /** ต้องไม่ throw เมื่อ hash ผิดรูป · คืน false แทน */
  verify(hash: string, plain: string): Promise<boolean>
}

export interface TokenSigner {
  sign(claims: Omit<AccessClaims, 'iat' | 'exp'>): Promise<string>
}

/** hash ที่ใช้ทั้งกับ refresh token และ identifier · ไม่มี salt เพราะต้องค้นหาได้ */
function sha256(v: string | Buffer): Buffer {
  return createHash('sha256').update(v).digest()
}

/** refresh token · 256 บิตจาก CSPRNG · ค่านี้ไม่เคยถูกเก็บลงฐานข้อมูล */
function newRefreshToken(): string {
  return randomBytes(32).toString('base64url')
}

export class AuthService {
  constructor(
    private readonly db: PrismaClient,
    private readonly hasher: PasswordHasher,
    private readonly signer: TokenSigner,
  ) {}

  // ===================================================================
  // 1 · LOGIN
  // ===================================================================
  async login(
    dto: LoginRequest,
    ctx: { ipHash: Buffer; userAgentHash?: Buffer },
  ): Promise<{ ok: true; body: LoginResponse; refreshToken: string } | { ok: false; code: 'INVALID_CREDENTIALS' | 'ACCOUNT_LOCKED' }> {
    const emailNormalized = normalizeEmail(dto.email)
    const identifierHash = sha256(emailNormalized)

    // ---- ล็อกบัญชีก่อนทำอย่างอื่น --------------------------------------
    const lock = await this.db.loginLockout.findUnique({ where: { identifierHash } })
    if (lock && lock.lockedUntil > new Date()) {
      return { ok: false, code: 'ACCOUNT_LOCKED' }
    }

    const admin = await this.db.merchantAdmin.findUnique({
      where: { emailNormalized },
      include: { merchant: true },
    })

    // ---- ต้องรัน verify แม้หาไม่เจอ ------------------------------------
    // ถ้าข้ามไป เวลาตอบกลับจะต่างกันชัดเจน แล้ว endpoint นี้จะกลายเป็น
    // เครื่องมือไล่หาว่าอีเมลไหนมีอยู่ในระบบ
    const hashToCheck = admin?.passwordHash ?? DUMMY_ARGON2ID
    const passwordOk = await this.hasher.verify(hashToCheck, dto.password)

    const allowed = Boolean(admin) && passwordOk && admin!.disabledAt === null

    if (!allowed) {
      await this.recordFailure(identifierHash, ctx.ipHash)
      // บัญชีถูกปิด รหัสผิด หรือไม่มีอีเมลนี้ → ตอบเหมือนกันหมด
      return { ok: false, code: 'INVALID_CREDENTIALS' }
    }

    // ---- สำเร็จ · เคลียร์ตัวนับแล้วเปิด session ใหม่ ----------------------
    const refreshToken = newRefreshToken()
    const sessionId = ('ses_' + short()) as SessionId
    const familyId = ('fam_' + short()) as FamilyId
    const expiresAt = new Date(Date.now() + REFRESH_TTL_SECONDS * 1000)

    await this.db.$transaction(async (tx) => {
      await tx.authSession.create({
        data: {
          id: sessionId,
          subjectKind: 'MERCHANT_ADMIN',
          merchantAdminId: admin!.id,
          familyId,
          refreshTokenHash: sha256(refreshToken),
          userAgentHash: ctx.userAgentHash ?? null,
          ipHash: ctx.ipHash,
          expiresAt,
        },
      })
      await tx.loginAttempt.create({
        data: { id: 'la_' + short(), identifierHash, ipHash: ctx.ipHash, succeeded: true },
      })
      await tx.loginLockout.deleteMany({ where: { identifierHash } })
      await tx.merchantAdmin.update({
        where: { id: admin!.id },
        data: { lastLoginAt: new Date() },
      })
      await tx.authEvent.create({
        data: {
          id: 'aev_' + short(),
          subjectKind: 'MERCHANT_ADMIN',
          subjectId: admin!.id,
          kind: 'LOGIN_OK',
          sessionId,
          ipHash: ctx.ipHash,
        },
      })
    })

    const accessToken = await this.signer.sign({
      sub: admin!.id,
      kind: 'MERCHANT_ADMIN',
      mid: admin!.merchantId as MerchantId,
      sid: sessionId,
      jti: randomUUID(),
    })

    return {
      ok: true,
      refreshToken,
      body: {
        accessToken,
        tokenType: 'Bearer',
        expiresIn: ACCESS_TTL_SECONDS,
        subject: {
          kind: 'MERCHANT_ADMIN',
          id: admin!.id,
          merchantId: admin!.merchantId as MerchantId,
          merchantStatus: admin!.merchant.status,
        },
      },
    }
  }

  // ===================================================================
  // 2 · REFRESH · หมุนทุกครั้ง และจับการใช้ซ้ำ
  // ===================================================================
  async refresh(presented: string, ctx: { ipHash: Buffer }): Promise<RefreshOutcome> {
    const tokenHash = sha256(presented)

    return this.db.$transaction(async (tx) => {
      const current = await tx.authSession.findUnique({
        where: { refreshTokenHash: tokenHash },
      })
      if (!current) return { outcome: 'invalid' }

      // ---- ใช้ไปแล้ว = มีสองเครื่องถือใบเดียวกัน = ถูกขโมย -----------------
      // ไม่ใช่แค่ปฏิเสธ request นี้ · ต้องเพิกถอนทั้งสาย
      if (current.usedAt !== null) {
        const revoked = await tx.authSession.updateMany({
          where: { familyId: current.familyId, revokedAt: null },
          data: { revokedAt: new Date(), revokedReason: 'REUSE_DETECTED' },
        })
        await tx.authEvent.create({
          data: {
            id: 'aev_' + short(),
            subjectKind: current.subjectKind,
            subjectId: current.merchantAdminId ?? current.customerId,
            kind: 'REUSE_DETECTED',
            sessionId: current.id,
            ipHash: ctx.ipHash,
            metadata: { familyId: current.familyId },
          },
        })
        return {
          outcome: 'compromised',
          familyId: current.familyId as FamilyId,
          revokedCount: revoked.count,
        }
      }

      if (current.revokedAt !== null) return { outcome: 'revoked' }
      if (current.expiresAt <= new Date()) return { outcome: 'expired' }

      // ---- หมุน ------------------------------------------------------
      const nextToken = newRefreshToken()
      const nextId = ('ses_' + short()) as SessionId

      await tx.authSession.update({
        where: { id: current.id },
        data: { usedAt: new Date(), revokedAt: new Date(), revokedReason: 'ROTATED' },
      })

      // uq_session_parent เป็นตัวตัดสินว่าหมุนซ้ำได้หรือไม่
      // ถ้าสอง request เข้ามาพร้อมกันด้วย token ใบเดียวกัน
      // ตัวที่สองจะชน unique ตรงนี้ ไม่ต้องล็อกแถวไว้ก่อน
      await tx.authSession.create({
        data: {
          id: nextId,
          subjectKind: current.subjectKind,
          merchantAdminId: current.merchantAdminId,
          customerId: current.customerId,
          familyId: current.familyId,
          refreshTokenHash: sha256(nextToken),
          parentId: current.id,
          userAgentHash: current.userAgentHash,
          ipHash: ctx.ipHash,
          expiresAt: new Date(Date.now() + REFRESH_TTL_SECONDS * 1000),
        },
      })

      await tx.authEvent.create({
        data: {
          id: 'aev_' + short(),
          subjectKind: current.subjectKind,
          subjectId: current.merchantAdminId ?? current.customerId,
          kind: 'REFRESH',
          sessionId: nextId,
          ipHash: ctx.ipHash,
        },
      })

      const accessToken = await this.signer.sign({
        sub: (current.merchantAdminId ?? current.customerId)!,
        kind: current.subjectKind,
        sid: nextId,
        jti: randomUUID(),
      })

      return { outcome: 'rotated', sessionId: nextId, refreshToken: nextToken, accessToken }
    })
  }

  // ===================================================================
  // 3 · LOGOUT · เพิกถอนเฉพาะเครื่องนี้
  // ===================================================================
  async logout(sessionId: SessionId): Promise<void> {
    await this.db.authSession.updateMany({
      where: { id: sessionId, revokedAt: null },
      data: { revokedAt: new Date(), revokedReason: 'LOGOUT' },
    })
    // เรียกซ้ำได้ · updateMany ที่ไม่เจอแถวไม่ throw จึงตอบ 204 เหมือนเดิม
  }

  /** ปิดบัญชีแล้วต้องเรียกตัวนี้ด้วย ไม่งั้น invariant T14 จะพัง */
  async revokeAllFor(subject: Subject, reason: 'ADMIN_REVOKED' | 'PASSWORD_CHANGED'): Promise<number> {
    const where =
      subject.kind === 'MERCHANT_ADMIN'
        ? { merchantAdminId: subject.id as AdminId, revokedAt: null }
        : { customerId: subject.id, revokedAt: null }
    const r = await this.db.authSession.updateMany({
      where,
      data: { revokedAt: new Date(), revokedReason: reason },
    })
    return r.count
  }

  // ------------------------------------------------------------------
  private async recordFailure(identifierHash: Buffer, ipHash: Buffer): Promise<void> {
    await this.db.$transaction(async (tx) => {
      await tx.loginAttempt.create({
        data: {
          id: 'la_' + short(),
          identifierHash,
          ipHash,
          succeeded: false,
          failureCode: 'BAD_CREDENTIALS',
        },
      })
      const since = new Date(Date.now() - LOCKOUT_WINDOW_SECONDS * 1000)
      const fails = await tx.loginAttempt.count({
        where: { identifierHash, succeeded: false, createdAt: { gt: since } },
      })
      if (fails >= LOCKOUT_THRESHOLD) {
        await tx.loginLockout.upsert({
          where: { identifierHash },
          create: {
            identifierHash,
            lockedUntil: new Date(Date.now() + LOCKOUT_WINDOW_SECONDS * 1000),
            attemptCount: fails,
          },
          update: {
            lockedUntil: new Date(Date.now() + LOCKOUT_WINDOW_SECONDS * 1000),
            attemptCount: fails,
          },
        })
      }
    })
  }
}

/**
 * hash ปลอมที่มี cost เท่าของจริง · ใช้ตอนหาอีเมลไม่เจอ
 * เพื่อให้เวลาตอบกลับของ "ไม่มีอีเมลนี้" เท่ากับ "รหัสผิด"
 */
const DUMMY_ARGON2ID =
  '$argon2id$v=19$m=65536,t=3,p=4$AAAAAAAAAAAAAAAAAAAAAA$' +
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

function short(): string {
  return randomUUID().replace(/-/g, '').slice(0, 12)
}

/** เทียบ hash แบบ constant-time · ใช้เมื่อต้องเทียบค่าลับเองนอกเหนือจาก argon2 */
export function safeEqual(a: Buffer, b: Buffer): boolean {
  return a.length === b.length && timingSafeEqual(a, b)
}
