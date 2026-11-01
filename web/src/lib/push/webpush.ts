// Web Push from the Worker with WebCrypto only (migration 0300): the VAPID header (RFC 8292, an ES256 JWT) and the
// message encryption (RFC 8291 with the aes128gcm content coding of RFC 8188). No Node crypto, no library: it runs in
// the Worker and in Node's tests alike. The keys are the URL-safe base64 forms the browsers and the usual
// "generate-vapid-keys" tools use: the public key is the 65-byte uncompressed P-256 point, the private key its 32-byte d.

const enc = new TextEncoder();

export function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const u = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = '';
  for (const b of u) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromB64url(s: string): Uint8Array<ArrayBuffer> {
  const t = s.replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '');
  const bin = atob(t + '='.repeat((4 - (t.length % 4)) % 4));
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(parts.reduce((n, p) => n + p.length, 0)));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

/** A VAPID key pair as the vault holds it: is it two well-formed P-256 keys? (Never logs them.) */
export function vapidKeysValid(publicKey: string | undefined, privateKey: string | undefined): boolean {
  if (!publicKey || !privateKey) return false;
  try {
    const pub = fromB64url(publicKey), d = fromB64url(privateKey);
    return pub.length === 65 && pub[0] === 4 && d.length === 32;
  } catch { return false; }
}

async function signingKey(publicKey: string, privateKey: string): Promise<CryptoKey> {
  const pub = fromB64url(publicKey);
  return crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x: b64url(pub.slice(1, 33)), y: b64url(pub.slice(33, 65)), d: privateKey, ext: false },
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
}

/** The Authorization header for one push service (the JWT's audience is its origin), valid 12 hours. */
export async function vapidAuthorization(endpoint: string, keys: { publicKey: string; privateKey: string; subject: string }, now = Date.now()): Promise<string> {
  const header = b64url(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = b64url(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(now / 1000) + 12 * 3600, sub: keys.subject })));
  const unsigned = `${header}.${claims}`;
  // WebCrypto's ECDSA signature is r || s (IEEE P1363), exactly what a JWS ES256 signature is
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, await signingKey(keys.publicKey, keys.privateKey), enc.encode(unsigned));
  return `vapid t=${unsigned}.${b64url(sig)}, k=${keys.publicKey}`;
}

async function hkdf(salt: Uint8Array<ArrayBuffer>, ikm: Uint8Array<ArrayBuffer>, info: Uint8Array<ArrayBuffer>, bytes: number): Promise<Uint8Array<ArrayBuffer>> {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, bytes * 8));
}

export const RECORD_SIZE = 4096;

/** The encrypted body for one subscription (RFC 8291): one aes128gcm record with the sender's key in its header. */
export async function encryptPayload(payload: string, sub: { p256dh: string; auth: string },
  opts: { salt?: Uint8Array<ArrayBuffer>; senderKeys?: CryptoKeyPair } = {}): Promise<Uint8Array<ArrayBuffer>> {
  const uaPublic = fromB64url(sub.p256dh), authSecret = fromB64url(sub.auth);
  if (uaPublic.length !== 65 || authSecret.length < 16) throw new Error('subscription keys are not P-256 keys');
  const sender = opts.senderKeys ?? (await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', sender.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, sender.privateKey, 256));
  const ikm = await hkdf(authSecret, ecdh, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = opts.salt ?? crypto.getRandomValues(new Uint8Array(new ArrayBuffer(16)));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const plain = concat(enc.encode(payload), new Uint8Array([2]));   // 2: the last (and only) record
  if (plain.length + 16 > RECORD_SIZE) throw new Error('payload too large for one record');
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, plain));
  const rs = new Uint8Array(4);
  new DataView(rs.buffer).setUint32(0, RECORD_SIZE);
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, cipher);
}

export type PushOutcome = { outcome: 'sent' | 'gone' | 'refused' | 'retry'; error?: string };

/** What a push service's answer means for the subscription (migration 0300, app.server_push_result). */
export function outcomeOf(status: number): PushOutcome {
  if (status >= 200 && status < 300) return { outcome: 'sent' };
  if (status === 404 || status === 410) return { outcome: 'gone', error: `HTTP ${status}` };
  if (status === 429 || status >= 500) return { outcome: 'retry', error: `HTTP ${status}` };
  return { outcome: 'refused', error: `HTTP ${status}` };
}

export interface PushMessage { endpoint: string; p256dh: string; auth: string; urgent?: boolean; payload: Record<string, unknown> }

/** One push, sent: encrypted, signed, posted. A network failure is a retry; nothing here throws. */
export async function sendPush(m: PushMessage, keys: { publicKey: string; privateKey: string; subject: string }, f: typeof fetch = fetch): Promise<PushOutcome> {
  try {
    if (!/^https:\/\//.test(m.endpoint)) return { outcome: 'gone', error: 'not an https endpoint' };
    const body = await encryptPayload(JSON.stringify(m.payload), m);
    const r = await f(m.endpoint, {
      method: 'POST', body,
      headers: { authorization: await vapidAuthorization(m.endpoint, keys), 'content-encoding': 'aes128gcm', 'content-type': 'application/octet-stream',
        ttl: String(m.urgent ? 4 * 3600 : 24 * 3600), urgency: m.urgent ? 'high' : 'normal' },
      signal: AbortSignal.timeout(10_000)
    });
    await r.arrayBuffer().catch(() => undefined);
    return outcomeOf(r.status);
  } catch (e) {
    return { outcome: 'retry', error: e instanceof Error ? e.message.slice(0, 200) : 'network' };
  }
}
