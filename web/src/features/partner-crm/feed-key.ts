// The key of a partner's read-only feed and widget (migration 0136): an HMAC of the partner and the key's version with the
// site's signing secret (LINK_SIGNING_KEY), so nothing secret is stored and "New key" (the version + 1) ends the old one.
// No imports: Worker and `node --test`.
const enc = new TextEncoder();

export async function feedKey(secret: string, partnerId: string, version: number): Promise<string> {
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(`carmacars-partner-feed-v1:${partnerId}:${version}`)));
  return Array.from(mac.slice(0, 20), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Constant time. */
export async function feedKeyOk(secret: string, partnerId: string, version: number, given: string | null | undefined): Promise<boolean> {
  const want = await feedKey(secret, partnerId, version);
  const got = String(given ?? '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  return d === 0;
}

export const PARTNER_COOKIE = 'cc-partner';
export const isUuid = (s: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(s);
