// The server's JWT keys (infra/vps/scripts/make-env.sh), the way the official supabase/docker utils/add-new-auth-keys.sh
// makes them, keeping what already exists:
//   JWT_KEYS  GoTrue's signing keys: this server's ES256 private key (made once, then kept) and the hosted project's
//             legacy HS256 secret (the anon and service_role keys are signed with it)
//   JWT_JWKS  what PostgREST, Storage and the functions verify with: the ES256 public key, the HS256 key and, unless
//             TRUST_HOSTED_JWKS=0, the hosted project's public signing keys, so a session token the hosted project
//             signed keeps working for the rest of its hour after the cutover
// Input (env): JWT_SECRET (required), JWT_KEYS (the current value, optional), HOSTED_JWKS (JSON, optional),
// TRUST_HOSTED_JWKS. Output: two lines, JWT_KEYS=<json> and JWT_JWKS=<json>, for the server's .env only.
import crypto from 'node:crypto';

const secret = process.env.JWT_SECRET ?? '';
if (secret.length < 32) { console.error('jwt-keys: JWT_SECRET is missing or shorter than 32 characters'); process.exit(1); }
const oct = { kty: 'oct', k: Buffer.from(secret).toString('base64url'), alg: 'HS256' };

let ec = null;
try {
  const prev = JSON.parse(process.env.JWT_KEYS || '[]');
  ec = Array.isArray(prev) ? prev.find((k) => k && k.kty === 'EC' && k.d && k.kid) ?? null : null;
} catch { ec = null; }
if (!ec) {
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const j = privateKey.export({ format: 'jwk' });
  ec = { kty: 'EC', kid: crypto.randomUUID(), use: 'sig', key_ops: ['sign', 'verify'], alg: 'ES256', ext: true, crv: j.crv, x: j.x, y: j.y, d: j.d };
}
const ecPublic = { kty: 'EC', kid: ec.kid, use: 'sig', key_ops: ['verify'], alg: 'ES256', ext: true, crv: ec.crv, x: ec.x, y: ec.y };

let hosted = [];
if (process.env.TRUST_HOSTED_JWKS !== '0' && process.env.HOSTED_JWKS) {
  try {
    const h = JSON.parse(process.env.HOSTED_JWKS);
    hosted = (Array.isArray(h.keys) ? h.keys : [])
      .filter((k) => k && (k.kty === 'EC' || k.kty === 'RSA') && k.kid && !k.d && k.kid !== ec.kid)
      .map((k) => Object.fromEntries(Object.entries({ kty: k.kty, kid: k.kid, use: 'sig', key_ops: ['verify'], alg: k.alg, crv: k.crv, x: k.x, y: k.y, n: k.n, e: k.e, ext: true }).filter(([, v]) => v !== undefined)));
  } catch { hosted = []; }
}

console.log(`JWT_KEYS=${JSON.stringify([ec, oct])}`);
console.log(`JWT_JWKS=${JSON.stringify({ keys: [ecPublic, oct, ...hosted] })}`);
console.error(`jwt-keys: ES256 key ${ec.kid}${process.env.JWT_KEYS?.includes(ec.kid) ? ' (kept)' : ' (new)'}; hosted public keys trusted: ${hosted.length}`);
