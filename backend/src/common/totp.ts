import { createHmac, randomBytes, timingSafeEqual } from 'crypto';

/** Dvostepena prijava (TOTP, RFC 6238): isti kodovi kao Google Authenticator, Microsoft Authenticator, Authy. */
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function newTotpSecret() {
  const bytes = randomBytes(20);
  let bits = '';
  for (const b of bytes) bits += b.toString(2).padStart(8, '0');
  let out = '';
  for (let i = 0; i + 5 <= bits.length; i += 5) out += B32[parseInt(bits.slice(i, i + 5), 2)];
  return out;
}

function decode(secret: string) {
  let bits = '';
  for (const c of secret.replace(/=+$/, '').toUpperCase()) {
    const v = B32.indexOf(c);
    if (v >= 0) bits += v.toString(2).padStart(5, '0');
  }
  const bytes: number[] = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(bytes);
}

function codeAt(secret: string, counter: number) {
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(counter));
  const h = createHmac('sha1', decode(secret)).update(buf).digest();
  const o = h[h.length - 1] & 0xf;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1_000_000).padStart(6, '0');
}

/** Tačan kod za sada (dozvoljeno ±30 s zbog sata telefona). */
export function verifyTotp(secret: string, code: string, now = Date.now()) {
  const c = String(code ?? '').replace(/\s/g, '');
  if (!/^\d{6}$/.test(c)) return false;
  const step = Math.floor(now / 30_000);
  return [-1, 0, 1].some((d) => {
    const exp = Buffer.from(codeAt(secret, step + d));
    return timingSafeEqual(exp, Buffer.from(c));
  });
}

export const totpCode = (secret: string, now = Date.now()) => codeAt(secret, Math.floor(now / 30_000));

export function totpUrl(secret: string, account: string) {
  const issuer = 'Poker klub Triling';
  return `otpauth://totp/${encodeURIComponent(issuer)}:${encodeURIComponent(account)}?secret=${secret}&issuer=${encodeURIComponent(issuer)}&digits=6&period=30`;
}
