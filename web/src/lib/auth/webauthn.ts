// Passkeys (release 48, migration 3170): checks what a phone's authenticator answers, with WebCrypto only. Two steps:
//   registration  the phone made a key pair; we read its credential id and public key from the attestation object.
//                 Attestation statements are not checked ("none" is what passkeys give): we trust the key because the
//                 person adding it is signed in, not because of who made the phone.
//   assertion     the phone signed our challenge; we check the signature with the stored public key.
// Both check that the answer is for our challenge, our site (the relying party id's hash) and an origin we expect: the
// website for the iPhone app (it presents the associated domain), "android:apk-key-hash:<hash>" for the Android app.
// No imports: the unit test runs it in Node (webauthn.test.ts).

export interface PublicJwk { kty: 'EC' | 'RSA'; crv?: string; x?: string; y?: string; n?: string; e?: string }
export interface Expectation { challenge: string; rpId: string; origins: readonly string[]; requireUserVerification?: boolean }
export type Check<T> = ({ ok: true } & T) | { ok: false; reason: string };

const te = new TextEncoder();
const td = new TextDecoder();

export function b64uToBytes(s: string): Uint8Array<ArrayBuffer> {
  const t = s.replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '');
  const bin = atob(t + '='.repeat((4 - (t.length % 4)) % 4));
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function bytesToB64u(b: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]!);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
const sha256 = async (b: Uint8Array<ArrayBuffer>) => new Uint8Array(await crypto.subtle.digest('SHA-256', b));
const same = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((v, i) => v === b[i]);

/** The Android app's origin for each signing certificate: "android:apk-key-hash:" and the SHA-256 fingerprint in base64url. */
export function androidOrigins(fingerprints: string | null | undefined): string[] {
  return (fingerprints ?? '').split(/[\s,]+/).map((f) => f.trim().toUpperCase()).filter((f) => /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(f))
    .map((f) => `android:apk-key-hash:${bytesToB64u(Uint8Array.from(f.split(':').map((h) => parseInt(h, 16))))}`);
}

// ---------------------------------------------------------------- CBOR (the subset authenticators use)
type Cbor = number | string | Uint8Array | Cbor[] | Map<number | string, Cbor> | boolean | null;
function cbor(buf: Uint8Array, at: number, depth = 0): [Cbor, number] {
  if (depth > 8 || at >= buf.length) throw new Error('cbor');
  const first = buf[at]!;
  const major = first >> 5;
  const info = first & 31;
  let p = at + 1;
  let n = info;
  if (info === 24) { n = buf[p]!; p += 1; }
  else if (info === 25) { n = (buf[p]! << 8) | buf[p + 1]!; p += 2; }
  else if (info === 26) { n = buf[p]! * 2 ** 24 + ((buf[p + 1]! << 16) | (buf[p + 2]! << 8) | buf[p + 3]!); p += 4; }
  else if (info > 26 && !(major === 7)) throw new Error('cbor');
  if (p > buf.length) throw new Error('cbor');
  if (major === 0) return [n, p];
  if (major === 1) return [-1 - n, p];
  if (major === 2 || major === 3) {
    if (p + n > buf.length) throw new Error('cbor');
    const part = buf.subarray(p, p + n);
    return [major === 2 ? part : td.decode(part), p + n];
  }
  if (major === 4) {
    const out: Cbor[] = [];
    for (let i = 0; i < n; i++) { const [v, q] = cbor(buf, p, depth + 1); out.push(v); p = q; }
    return [out, p];
  }
  if (major === 5) {
    const out = new Map<number | string, Cbor>();
    for (let i = 0; i < n; i++) {
      const [k, q] = cbor(buf, p, depth + 1);
      const [v, r] = cbor(buf, q, depth + 1);
      if (typeof k !== 'number' && typeof k !== 'string') throw new Error('cbor');
      out.set(k, v); p = r;
    }
    return [out, p];
  }
  if (major === 7 && (info === 20 || info === 21)) return [info === 21, at + 1];
  if (major === 7 && info === 22) return [null, at + 1];
  throw new Error('cbor');
}

// ---------------------------------------------------------------- authenticator data
export interface AuthData { rpIdHash: Uint8Array; userPresent: boolean; userVerified: boolean; signCount: number; credentialId?: Uint8Array; jwk?: PublicJwk; alg?: number }
export function parseAuthData(d: Uint8Array): AuthData {
  if (d.length < 37) throw new Error('authenticator data');
  const flags = d[32]!;
  const out: AuthData = { rpIdHash: d.subarray(0, 32), userPresent: (flags & 1) !== 0, userVerified: (flags & 4) !== 0,
    signCount: d[33]! * 2 ** 24 + ((d[34]! << 16) | (d[35]! << 8) | d[36]!) };
  if (flags & 64) {
    if (d.length < 55) throw new Error('authenticator data');
    const len = (d[53]! << 8) | d[54]!;
    if (len < 1 || len > 1023 || 55 + len > d.length) throw new Error('authenticator data');
    out.credentialId = d.subarray(55, 55 + len);
    const [key] = cbor(d, 55 + len);
    if (!(key instanceof Map)) throw new Error('key');
    const alg = key.get(3);
    const bytes = (k: number) => { const v = key.get(k); if (!(v instanceof Uint8Array)) throw new Error('key'); return bytesToB64u(v); };
    if (key.get(1) === 2 && alg === -7 && key.get(-1) === 1) out.jwk = { kty: 'EC', crv: 'P-256', x: bytes(-2), y: bytes(-3) };
    else if (key.get(1) === 3 && alg === -257) out.jwk = { kty: 'RSA', n: bytes(-1), e: bytes(-2) };
    else throw new Error('This kind of passkey is not supported');
    out.alg = alg as number;
  }
  return out;
}

async function clientData(b64: string, type: string, e: Expectation): Promise<{ ok: true; hash: Uint8Array } | { ok: false; reason: string }> {
  const raw = b64uToBytes(b64);
  let c: { type?: string; challenge?: string; origin?: string; crossOrigin?: boolean };
  try { c = JSON.parse(td.decode(raw)) as typeof c; } catch { return { ok: false, reason: 'client data' }; }
  if (c.type !== type) return { ok: false, reason: 'type' };
  if (typeof c.challenge !== 'string' || !same(b64uToBytes(c.challenge), b64uToBytes(e.challenge))) return { ok: false, reason: 'challenge' };
  if (typeof c.origin !== 'string' || !e.origins.includes(c.origin)) return { ok: false, reason: 'origin' };
  if (c.crossOrigin === true) return { ok: false, reason: 'cross origin' };
  return { ok: true, hash: await sha256(raw) };
}
async function common(a: AuthData, e: Expectation): Promise<string | null> {
  if (!same(a.rpIdHash, await sha256(te.encode(e.rpId)))) return 'relying party';
  if (!a.userPresent) return 'user presence';
  if (e.requireUserVerification !== false && !a.userVerified) return 'user verification';
  return null;
}

/** A new passkey: its credential id and public key, once the answer is for our challenge, site and app. */
export async function checkRegistration(r: { clientDataJSON: string; attestationObject: string }, e: Expectation):
  Promise<Check<{ credentialId: string; jwk: PublicJwk; alg: number; signCount: number }>> {
  try {
    const c = await clientData(r.clientDataJSON, 'webauthn.create', e);
    if (!c.ok) return c;
    const [att] = cbor(b64uToBytes(r.attestationObject), 0);
    const data = att instanceof Map ? att.get('authData') : null;
    if (!(data instanceof Uint8Array)) return { ok: false, reason: 'attestation' };
    const a = parseAuthData(data);
    const bad = await common(a, e);
    if (bad) return { ok: false, reason: bad };
    if (!a.credentialId || !a.jwk || a.alg === undefined) return { ok: false, reason: 'no credential' };
    return { ok: true, credentialId: bytesToB64u(a.credentialId), jwk: a.jwk, alg: a.alg, signCount: a.signCount };
  } catch (err) {
    return { ok: false, reason: err instanceof Error ? err.message : 'unreadable' };
  }
}

/** ECDSA signatures arrive in ASN.1 DER; WebCrypto wants r and s side by side (32 bytes each for P-256). */
export function derToRaw(der: Uint8Array, size = 32): Uint8Array<ArrayBuffer> | null {
  if (der[0] !== 0x30) return null;
  let p = 2;
  if (der[1]! & 0x80) p = 2 + (der[1]! & 0x7f);
  const out = new Uint8Array(new ArrayBuffer(size * 2));
  for (let i = 0; i < 2; i++) {
    if (der[p] !== 0x02) return null;
    const len = der[p + 1]!;
    let v = der.subarray(p + 2, p + 2 + len);
    if (v.length !== len) return null;
    while (v.length > size && v[0] === 0) v = v.subarray(1);
    if (v.length > size) return null;
    out.set(v, i * size + (size - v.length));
    p += 2 + len;
  }
  return out;
}

/** A sign-in: the signature over the authenticator data and the client data's hash, checked with the stored key. */
export async function checkAssertion(r: { clientDataJSON: string; authenticatorData: string; signature: string }, e: Expectation & { jwk: PublicJwk; alg: number }):
  Promise<Check<{ signCount: number; userVerified: boolean }>> {
  try {
    const c = await clientData(r.clientDataJSON, 'webauthn.get', e);
    if (!c.ok) return c;
    const data = b64uToBytes(r.authenticatorData);
    const a = parseAuthData(data);
    const bad = await common(a, e);
    if (bad) return { ok: false, reason: bad };
    const signed = new Uint8Array(new ArrayBuffer(data.length + c.hash.length));
    signed.set(data, 0); signed.set(c.hash, data.length);
    const sig = b64uToBytes(r.signature);
    let ok = false;
    if (e.alg === -7 && e.jwk.kty === 'EC') {
      const key = await crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x: e.jwk.x, y: e.jwk.y }, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
      const raw = derToRaw(sig);
      ok = !!raw && await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, raw, signed);
    } else if (e.alg === -257 && e.jwk.kty === 'RSA') {
      const key = await crypto.subtle.importKey('jwk', { kty: 'RSA', n: e.jwk.n, e: e.jwk.e }, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
      ok = await crypto.subtle.verify({ name: 'RSASSA-PKCS1-v1_5' }, key, sig, signed);
    }
    return ok ? { ok: true, signCount: a.signCount, userVerified: a.userVerified } : { ok: false, reason: 'signature' };
  } catch (err) {
    return { ok: false, reason: err instanceof Error ? err.message : 'unreadable' };
  }
}
