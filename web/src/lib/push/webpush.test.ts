import { test } from 'node:test';
import assert from 'node:assert/strict';
import { b64url, encryptPayload, fromB64url, outcomeOf, sendPush, vapidAuthorization, vapidKeysValid, RECORD_SIZE } from './webpush.ts';

// Web Push (migration 0300): the encryption against RFC 8291's own example, a round trip with fresh keys, the VAPID
// header verified with the public key, and what each push service answer means. Keys here are made in the test or are
// the RFC's published example keys; none is ever a real key.

const RFC = {
  plaintext: 'When I grow up, I want to be a watermelon',
  asPublic: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  asPrivate: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
  uaPublic: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
  uaPrivate: 'q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94',
  salt: 'DGv6ra1nlYgDCS1FRnbzlw',
  auth: 'BTBZMqHH6r4Tts7J_aSIgg',
  message: 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN'
};

const jwk = (pub: string, d?: string) => {
  const p = fromB64url(pub);
  return { kty: 'EC', crv: 'P-256', x: b64url(p.slice(1, 33)), y: b64url(p.slice(33, 65)), ...(d ? { d } : {}), ext: true };
};

async function hkdf(salt: Uint8Array<ArrayBuffer>, ikm: Uint8Array<ArrayBuffer>, info: string | Uint8Array<ArrayBuffer>, n: number) {
  const k = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  const i = typeof info === 'string' ? new TextEncoder().encode(info) : info;
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info: i }, k, n * 8));
}

/** What the browser does with a push: the receiving side of RFC 8291, written out separately from the sender. */
async function decrypt(body: Uint8Array<ArrayBuffer>, uaPublic: string, uaPrivate: string, auth: string): Promise<string> {
  const salt = body.slice(0, 16);
  const rs = new DataView(body.buffer, body.byteOffset + 16, 4).getUint32(0);
  const idlen = body[20]!;
  const asPublic = body.slice(21, 21 + idlen);
  const cipher = body.slice(21 + idlen);
  assert.equal(rs, RECORD_SIZE);
  const priv = await crypto.subtle.importKey('jwk', jwk(uaPublic, uaPrivate), { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  const asKey = await crypto.subtle.importKey('raw', asPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: asKey }, priv, 256));
  const ua = fromB64url(uaPublic);
  const info = new Uint8Array([...new TextEncoder().encode('WebPush: info\0'), ...ua, ...asPublic]);
  const ikm = await hkdf(fromB64url(auth), ecdh, info, 32);
  const cek = await hkdf(salt, ikm, 'Content-Encoding: aes128gcm\0', 16);
  const nonce = await hkdf(salt, ikm, 'Content-Encoding: nonce\0', 12);
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt']);
  const plain = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, key, cipher));
  assert.equal(plain[plain.length - 1], 2, 'the last record ends with the delimiter 2');
  return new TextDecoder().decode(plain.slice(0, -1));
}

async function freshVapid() {
  const k = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const j = await crypto.subtle.exportKey('jwk', k.privateKey);
  const pub = new Uint8Array(await crypto.subtle.exportKey('raw', k.publicKey));
  return { publicKey: b64url(pub), privateKey: j.d!, verify: k.publicKey };
}

test('RFC 8291 appendix A: the same message, byte for byte', async () => {
  const senderKeys = {
    privateKey: await crypto.subtle.importKey('jwk', jwk(RFC.asPublic, RFC.asPrivate), { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']),
    publicKey: await crypto.subtle.importKey('jwk', jwk(RFC.asPublic), { name: 'ECDH', namedCurve: 'P-256' }, true, [])
  } as CryptoKeyPair;
  const body = await encryptPayload(RFC.plaintext, { p256dh: RFC.uaPublic, auth: RFC.auth }, { salt: fromB64url(RFC.salt), senderKeys });
  assert.equal(b64url(body), RFC.message);
  assert.equal(await decrypt(body, RFC.uaPublic, RFC.uaPrivate, RFC.auth), RFC.plaintext);
});

test('a round trip with fresh keys: the browser reads what was sent', async () => {
  const ua = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const uaPublic = b64url(await crypto.subtle.exportKey('raw', ua.publicKey));
  const uaPrivate = (await crypto.subtle.exportKey('jwk', ua.privateKey)).d!;
  const auth = b64url(crypto.getRandomValues(new Uint8Array(16)));
  const payload = JSON.stringify({ title: 'New booking request CC-1042', body: 'Pickup Friday 10:00', url: '/admin/requests' });
  const body = await encryptPayload(payload, { p256dh: uaPublic, auth });
  assert.equal(await decrypt(body, uaPublic, uaPrivate, auth), payload);
  await assert.rejects(encryptPayload('x'.repeat(5000), { p256dh: uaPublic, auth }), /too large/);
  await assert.rejects(encryptPayload('x', { p256dh: 'AAAA', auth }), /not P-256/);
});

test('VAPID: an ES256 token for the push service origin, signed with the private key, with the public key beside it', async () => {
  const v = await freshVapid();
  const now = Date.UTC(2026, 10, 1, 12);
  const h = await vapidAuthorization('https://fcm.googleapis.com/fcm/send/abc', { ...v, subject: 'https://carmacars.example.test' }, now);
  const m = /^vapid t=([^.]+)\.([^.]+)\.([^,]+), k=(.+)$/.exec(h);
  assert.ok(m, h);
  assert.equal(m[4], v.publicKey);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromB64url(m[1]!))), { typ: 'JWT', alg: 'ES256' });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromB64url(m[2]!))), { aud: 'https://fcm.googleapis.com', exp: now / 1000 + 12 * 3600, sub: 'https://carmacars.example.test' });
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, v.verify, fromB64url(m[3]!), new TextEncoder().encode(`${m[1]}.${m[2]}`));
  assert.equal(ok, true);
});

test('the key check: two well-formed keys, or push stays off', async () => {
  const v = await freshVapid();
  assert.equal(vapidKeysValid(v.publicKey, v.privateKey), true);
  assert.equal(vapidKeysValid(undefined, v.privateKey), false);
  assert.equal(vapidKeysValid(v.publicKey, ''), false);
  assert.equal(vapidKeysValid('not a key', v.privateKey), false);
  assert.equal(vapidKeysValid(v.privateKey, v.publicKey), false);
});

test('push service answers: 201 sent, 404 and 410 gone (the subscription is pruned), 429 and 5xx retry, the rest refused', () => {
  assert.equal(outcomeOf(201).outcome, 'sent');
  assert.equal(outcomeOf(404).outcome, 'gone');
  assert.equal(outcomeOf(410).outcome, 'gone');
  assert.equal(outcomeOf(429).outcome, 'retry');
  assert.equal(outcomeOf(503).outcome, 'retry');
  assert.equal(outcomeOf(403).outcome, 'refused');
  assert.equal(outcomeOf(400).outcome, 'refused');
});

test('sendPush: the headers a push service needs; a network error is a retry, never a throw', async () => {
  const v = await freshVapid();
  const ua = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const sub = { endpoint: 'https://push.example.test/send/1', p256dh: b64url(await crypto.subtle.exportKey('raw', ua.publicKey)), auth: b64url(crypto.getRandomValues(new Uint8Array(16))) };
  let seen: { url: string; headers: Record<string, string> } | null = null;
  const f = (async (url: string, init: RequestInit) => { seen = { url, headers: init.headers as Record<string, string> }; return new Response(null, { status: 410 }); }) as unknown as typeof fetch;
  const r = await sendPush({ ...sub, urgent: true, payload: { title: 'x' } }, { ...v, subject: 'https://carmacars.example.test' }, f);
  assert.equal(r.outcome, 'gone');
  const s = seen as unknown as { url: string; headers: Record<string, string> };
  assert.equal(s.url, sub.endpoint);
  assert.equal(s.headers['content-encoding'], 'aes128gcm');
  assert.equal(s.headers.urgency, 'high');
  assert.match(s.headers.authorization!, /^vapid t=/);
  const boom = (async () => { throw new Error('offline'); }) as unknown as typeof fetch;
  assert.deepEqual(await sendPush({ ...sub, payload: {} }, { ...v, subject: 'https://carmacars.example.test' }, boom), { outcome: 'retry', error: 'offline' });
});
