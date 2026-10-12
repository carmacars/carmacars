// Stripe's webhook signature (the Stripe-Signature header: t=<seconds>,v1=<hex HMAC-SHA256 of "t.body">),
// checked with WebCrypto so it runs in the Worker. Events older than the tolerance are refused
// (docs/blueprint/13-security.md section 8).
const enc = new TextEncoder();

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(message)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('');
}

function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export async function verifyStripeSignature(rawBody: string, header: string | null, secret: string, nowSeconds = Math.floor(Date.now() / 1000), toleranceSeconds = 300): Promise<void> {
  if (!secret) throw new Error('No webhook secret configured');
  if (!header) throw new Error('Missing signature header');
  const parts = header.split(',').map((p) => p.split('=') as [string, string]);
  const t = Number(parts.find(([k]) => k === 't')?.[1]);
  const v1 = parts.filter(([k]) => k === 'v1').map(([, v]) => v);
  if (!Number.isFinite(t) || !v1.length) throw new Error('Malformed signature header');
  if (Math.abs(nowSeconds - t) > toleranceSeconds) throw new Error('Signature timestamp outside the tolerance');
  const want = await hmacHex(secret, `${t}.${rawBody}`);
  if (!v1.some((s) => same(s, want))) throw new Error('Signature does not match');
}

/** For tests and the fake adapter: the header Stripe would send for this body. */
export async function signStripePayload(rawBody: string, secret: string, t = Math.floor(Date.now() / 1000)): Promise<string> {
  return `t=${t},v1=${await hmacHex(secret, `${t}.${rawBody}`)}`;
}
