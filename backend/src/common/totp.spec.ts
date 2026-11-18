import { newTotpSecret, totpCode, verifyTotp } from './totp';

describe('2FA (TOTP)', () => {
  it('RFC 6238 primer', () => {
    // Tajni ključ "12345678901234567890" u base32.
    const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
    expect(totpCode(secret, 59_000)).toBe('287082');
    expect(verifyTotp(secret, '287082', 59_000)).toBe(true);
    expect(verifyTotp(secret, '000000', 59_000)).toBe(false);
  });
  it('novi ključ radi sa svojim kodom', () => {
    const s = newTotpSecret();
    expect(s).toMatch(/^[A-Z2-7]{32}$/);
    expect(verifyTotp(s, totpCode(s))).toBe(true);
  });
});
