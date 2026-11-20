import { test } from 'node:test';
import assert from 'node:assert/strict';
import { androidOrigins, b64uToBytes, bytesToB64u, checkAssertion, checkRegistration, derToRaw } from './webauthn.ts';

// A phone's authenticator, made here: a P-256 key, the attestation object of a new passkey and a signed sign-in.
const te = new TextEncoder();
const RP = 'carmacars.ca';
const ORIGINS = ['https://carmacars.ca', ...androidOrigins('AA:'.repeat(31) + 'AA')];
const cat = (...parts: Uint8Array[]) => { const o = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { o.set(p, at); at += p.length; } return o; };
const sha = async (b: Uint8Array) => new Uint8Array(await crypto.subtle.digest('SHA-256', b as Uint8Array<ArrayBuffer>));
const bstr = (b: Uint8Array) => cat(b.length < 24 ? Uint8Array.of(0x40 + b.length) : b.length < 256 ? Uint8Array.of(0x58, b.length) : Uint8Array.of(0x59, b.length >> 8, b.length & 255), b);
const tstr = (s: string) => cat(Uint8Array.of(0x60 + s.length), te.encode(s));

async function phone() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey('jwk', pair.publicKey);
  const id = crypto.getRandomValues(new Uint8Array(20));
  // COSE: {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x, -3: y}
  const cose = cat(Uint8Array.of(0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21), bstr(b64uToBytes(jwk.x!)), Uint8Array.of(0x22), bstr(b64uToBytes(jwk.y!)));
  const authData = async (flags: number, count: number, attested: boolean, rp = RP) => cat(await sha(te.encode(rp)), Uint8Array.of(flags, 0, 0, count >> 8, count & 255),
    ...(attested ? [new Uint8Array(16), Uint8Array.of(0, id.length), id, cose] : []));
  const client = (type: string, challenge: string, origin: string) => bytesToB64u(te.encode(JSON.stringify({ type, challenge, origin, crossOrigin: false })));
  const der = (raw: Uint8Array) => {
    const int = (v: Uint8Array) => { let x = v; while (x.length > 1 && x[0] === 0 && !(x[1]! & 0x80)) x = x.subarray(1); if (x[0]! & 0x80) x = cat(Uint8Array.of(0), x); return cat(Uint8Array.of(0x02, x.length), x); };
    const body = cat(int(raw.subarray(0, 32)), int(raw.subarray(32)));
    return cat(Uint8Array.of(0x30, body.length), body);
  };
  return {
    id: bytesToB64u(id),
    async register(challenge: string, origin = ORIGINS[0]!, flags = 0x45, rp = RP) {
      const att = cat(Uint8Array.of(0xa3), tstr('fmt'), tstr('none'), tstr('attStmt'), Uint8Array.of(0xa0), tstr('authData'), bstr(await authData(flags, 0, true, rp)));
      return { clientDataJSON: client('webauthn.create', challenge, origin), attestationObject: bytesToB64u(att) };
    },
    async assert(challenge: string, count: number, origin = ORIGINS[0]!, flags = 0x05) {
      const a = await authData(flags, count, false);
      const c = client('webauthn.get', challenge, origin);
      const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, cat(a, await sha(b64uToBytes(c)))));
      return { clientDataJSON: c, authenticatorData: bytesToB64u(a), signature: bytesToB64u(der(sig)) };
    }
  };
}
const challenge = () => bytesToB64u(crypto.getRandomValues(new Uint8Array(32)));

test('a new passkey: the credential id and the key are read once the challenge, the site and the app match', async () => {
  const p = await phone();
  const ch = challenge();
  const r = await checkRegistration(await p.register(ch), { challenge: ch, rpId: RP, origins: ORIGINS });
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.credentialId, p.id);
  assert.equal(r.alg, -7);
  assert.equal(r.jwk.kty, 'EC');
});

test('a new passkey is refused for another challenge, another site, another origin, or without the screen lock', async () => {
  const p = await phone();
  const ch = challenge();
  const e = { challenge: ch, rpId: RP, origins: ORIGINS };
  assert.deepEqual(await checkRegistration(await p.register(challenge()), e), { ok: false, reason: 'challenge' });
  assert.deepEqual(await checkRegistration(await p.register(ch, 'https://evil.example.test'), e), { ok: false, reason: 'origin' });
  assert.deepEqual(await checkRegistration(await p.register(ch, ORIGINS[0], 0x45, 'evil.example.test'), e), { ok: false, reason: 'relying party' });
  assert.deepEqual(await checkRegistration(await p.register(ch, ORIGINS[0], 0x41), e), { ok: false, reason: 'user verification' });
  assert.equal((await checkRegistration({ clientDataJSON: 'e30', attestationObject: 'AA' }, e)).ok, false);
});

test('a sign-in: the signature is checked with the stored key, from the website origin and from the Android app', async () => {
  const p = await phone();
  const ch0 = challenge();
  const reg = await checkRegistration(await p.register(ch0), { challenge: ch0, rpId: RP, origins: ORIGINS });
  assert.equal(reg.ok, true);
  if (!reg.ok) return;
  for (const origin of ORIGINS) {
    const ch = challenge();
    const r = await checkAssertion(await p.assert(ch, 7, origin), { challenge: ch, rpId: RP, origins: ORIGINS, jwk: reg.jwk, alg: reg.alg });
    assert.deepEqual(r, { ok: true, signCount: 7, userVerified: true });
  }
});

test('a sign-in is refused: a replayed answer, another phone\'s key, a changed counter, a registration answer', async () => {
  const [p, other] = [await phone(), await phone()];
  const ch0 = challenge();
  const reg = await checkRegistration(await p.register(ch0), { challenge: ch0, rpId: RP, origins: ORIGINS });
  const regOther = await checkRegistration(await other.register(ch0), { challenge: ch0, rpId: RP, origins: ORIGINS });
  if (!reg.ok || !regOther.ok) { assert.fail('registration'); return; }
  const ch = challenge();
  const answer = await p.assert(ch, 3);
  const e = { rpId: RP, origins: ORIGINS, jwk: reg.jwk, alg: reg.alg };
  assert.deepEqual(await checkAssertion(answer, { ...e, challenge: challenge() }), { ok: false, reason: 'challenge' });
  assert.deepEqual(await checkAssertion(answer, { ...e, challenge: ch, jwk: regOther.jwk }), { ok: false, reason: 'signature' });
  // the counter is inside what was signed: changing it breaks the signature
  const data = b64uToBytes(answer.authenticatorData); data[36] = 99;
  assert.deepEqual(await checkAssertion({ ...answer, authenticatorData: bytesToB64u(data) }, { ...e, challenge: ch }), { ok: false, reason: 'signature' });
  assert.deepEqual(await checkAssertion({ ...answer, clientDataJSON: (await p.register(ch)).clientDataJSON }, { ...e, challenge: ch }), { ok: false, reason: 'type' });
  assert.deepEqual(await checkAssertion(await p.assert(ch, 3, ORIGINS[0], 0x01), { ...e, challenge: ch }), { ok: false, reason: 'user verification' });
});

test('the Android origin is the certificate fingerprint in base64url; a malformed fingerprint gives none', () => {
  assert.deepEqual(androidOrigins('zz, 12:34'), []);
  const [o] = androidOrigins('aa:'.repeat(31) + 'aa');
  assert.equal(o, `android:apk-key-hash:${bytesToB64u(new Uint8Array(32).fill(0xaa))}`);
});

test('a DER signature becomes r and s side by side; anything else is refused', () => {
  const r = new Uint8Array(32).fill(0x11); const s = new Uint8Array(32).fill(0x7f);
  const der = Uint8Array.of(0x30, 68, 0x02, 32, ...r, 0x02, 32, ...s);
  assert.deepEqual([...derToRaw(der)!], [...r, ...s]);
  assert.equal(derToRaw(Uint8Array.of(0x31, 0)), null);
});
