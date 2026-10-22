import 'server-only';
import { workerToken } from '@/server/listing-worker';
import { linkSecret } from '@/server/links';

/** The jobs' bearer token (the listing worker's, derived from LINK_SIGNING_KEY), compared in constant time. */
export async function jobAuthorized(req: Request): Promise<boolean> {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  return d === 0;
}

/** The Turo-by-Gmail token (an Apps Script in rent@carmacars.ca posts Turo emails to /api/inbound/turo): derived from
 *  LINK_SIGNING_KEY like the jobs' token but for this one route only, so the script cannot run any other job. */
export async function turoGmailToken(): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(linkSecret()), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode('carmacars-turo-gmail-v1')));
  return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

export async function turoGmailAuthorized(req: Request): Promise<boolean> {
  const want = await turoGmailToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  return d === 0;
}
