// HMAC-signed links for the local storage route (/api/storage), the local equivalent of R2's
// presigned URLs: method, bucket, key, expiry and (for uploads) the content type are all signed.
const enc = new TextEncoder();
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function mac(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64url(new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(msg))));
}
const message = (method: string, bucket: string, key: string, exp: number, ct: string, fn: string) => [method, bucket, key, exp, ct, fn].join('\n');

export async function signStorageUrl(secret: string, method: 'GET' | 'PUT', bucket: string, key: string, ttl: number, o: { contentType?: string; filename?: string } = {}): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + ttl;
  const ct = o.contentType ?? ''; const fn = o.filename ?? '';
  const q = new URLSearchParams({ exp: String(exp), sig: await mac(secret, message(method, bucket, key, exp, ct, fn)) });
  if (fn) q.set('fn', fn);
  return `/api/storage/${bucket}/${key.split('/').map(encodeURIComponent).join('/')}?${q}`;
}

export async function checkStorageUrl(secret: string, method: string, bucket: string, key: string, q: URLSearchParams, contentType = ''): Promise<boolean> {
  const exp = Number(q.get('exp'));
  if (!Number.isFinite(exp) || exp < Math.floor(Date.now() / 1000)) return false;
  const want = await mac(secret, message(method, bucket, key, exp, method === 'PUT' ? contentType : '', q.get('fn') ?? ''));
  const got = q.get('sig') ?? '';
  if (got.length !== want.length) return false;
  let d = 0;
  for (let i = 0; i < got.length; i++) d |= got.charCodeAt(i) ^ want.charCodeAt(i);
  return d === 0;
}
