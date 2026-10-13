import 'server-only';
import { createHmac, randomBytes } from 'node:crypto';

// RFC 6238 time-based one-time codes (SHA-1, 30 seconds, 6 digits), the kind every authenticator app
// reads. Used by the local stand-in for Supabase Auth's TOTP factor; Supabase checks codes itself.
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export function newSecret(): string {
  const b = randomBytes(20); let bits = ''; let out = '';
  for (const x of b) bits += x.toString(2).padStart(8, '0');
  for (let i = 0; i + 5 <= bits.length; i += 5) out += B32[parseInt(bits.slice(i, i + 5), 2)];
  return out;
}
function decode(s: string): Buffer {
  let bits = '';
  for (const c of s.replace(/=+$/, '').toUpperCase()) { const v = B32.indexOf(c); if (v < 0) continue; bits += v.toString(2).padStart(5, '0'); }
  const bytes: number[] = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(bytes);
}
export function codeAt(secret: string, t = Date.now()): string {
  const c = Buffer.alloc(8); c.writeBigUInt64BE(BigInt(Math.floor(t / 30_000)));
  const h = createHmac('sha1', decode(secret)).update(c).digest();
  const o = h[h.length - 1]! & 0xf;
  return String(((h.readUInt32BE(o) & 0x7fffffff) % 1_000_000)).padStart(6, '0');
}
/** True when the code matches now or one step either side (clock drift). */
export function checkCode(secret: string, code: string, t = Date.now()): boolean {
  const c = code.replace(/\s/g, '');
  return /^\d{6}$/.test(c) && [-1, 0, 1].some((k) => codeAt(secret, t + k * 30_000) === c);
}
export const otpauthUri = (secret: string, email: string) => `otpauth://totp/${encodeURIComponent(`CarmaCars:${email}`)}?secret=${secret}&issuer=CarmaCars&algorithm=SHA1&digits=6&period=30`;
