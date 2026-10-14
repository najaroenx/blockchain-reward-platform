#!/usr/bin/env python3
"""
FEAT-02 · ตรวจ contract ของ api/openapi.yaml

ข้อเท็จจริงจากระบบเดิมห้าข้อของ pack นี้ สามข้อถูกกันที่ชั้น schema ของ API
ไม่ใช่ที่ชั้นฐานข้อมูล · จึงต้องมีตัวตรวจที่ชั้นนั้นด้วย

ไฟล์นี้ fail ถ้ามีใครเติมช่องที่ไม่ควรมีกลับเข้ามา
ซึ่งเป็นสิ่งที่เกิดได้ง่ายที่สุดเวลารีบ · F6 เองก็มีคอมเมนต์ว่า for testing
"""
import re
import sys

import yaml

SPEC = 'api/openapi.yaml'


def main() -> int:
    d = yaml.safe_load(open(SPEC, encoding='utf-8'))
    S = d['components']['schemas']
    bad: list[str] = []

    # F6 · คำตอบของ request OTP ต้องไม่มีช่องที่เก็บ OTP ได้
    acc = S['OtpChallengeAccepted']
    otpish = re.compile(r'(otp|^code$|plain|clear|secret)', re.I)
    bad += [f'F6 · OtpChallengeAccepted มีช่อง {k}'
            for k in acc['properties'] if otpish.search(k)]
    if acc.get('additionalProperties') is not False:
        bad.append('F6 · OtpChallengeAccepted ไม่ได้ปิด additionalProperties')

    # F7 · คำขอยืนยันต้องไม่มีช่องเบอร์โทร
    ver = S['VerifyOtpRequest']
    phoneish = re.compile(r'(phone|msisdn|mobile|tel)', re.I)
    bad += [f'F7 · VerifyOtpRequest มีช่อง {k}'
            for k in ver['properties'] if phoneish.search(k)]
    if ver.get('additionalProperties') is not False:
        bad.append('F7 · VerifyOtpRequest ไม่ได้ปิด additionalProperties')

    # F10 · F13 · L6 · ไม่มี schema ไหนที่มีช่องเกี่ยวกับ key
    keyish = re.compile(r'(private|privkey|mnemonic|seed|keystore|encrypted_?key)', re.I)
    # F12 · ไม่มี schema ไหนที่รับหรือคืนรหัสผ่าน
    pwish = re.compile(r'(password|passwd|pwd)', re.I)
    for name, sch in S.items():
        for k in (sch.get('properties') or {}):
            if keyish.search(k):
                bad.append(f'L6 · {name} มีช่อง {k}')
            if pwish.search(k):
                bad.append(f'F12 · {name} มีช่อง {k}')

    # F12 · ผลของการยืนยันต้องมี token · ไม่ใช่คืน 201 เปล่า
    if 'accessToken' not in S['VerifyOtpResult']['properties']:
        bad.append('F12 · VerifyOtpResult ไม่มี accessToken')

    if bad:
        for b in bad:
            print('ไม่ผ่าน · ' + b)
        return 1

    print(f'contract ของ {SPEC} · {len(S)} schemas · ผ่านทั้งหมด')
    print('  F6  ไม่มีช่อง OTP ในคำตอบ และปิด additionalProperties')
    print('  F7  ไม่มีช่องเบอร์โทรในคำขอยืนยัน และปิด additionalProperties')
    print('  F10 F13 L6  ไม่มี schema ไหนมีช่องเกี่ยวกับ key')
    print('  F12 ไม่มีช่องรหัสผ่าน และผลการยืนยันมี accessToken')
    return 0


if __name__ == '__main__':
    sys.exit(main())
