import 'server-only';
import { headers } from 'next/headers';
import { env } from '@/lib/env';
import { clientIp } from '@/lib/security/client-ip';

// Who is asking: the address Cloudflare saw (CF-Connecting-IP only in production: src/lib/security/client-ip.ts); the browser;
// and a request id for the audit log (docs/blueprint/00-overview.md section 2.3, step 7).
export async function requestMeta() {
  const h = await headers();
  const ip = clientIp((n) => h.get(n), env().APP_ENV !== 'local');
  return { ip, userAgent: (h.get('user-agent') ?? '').slice(0, 300), requestId: h.get('cf-ray') ?? crypto.randomUUID(), referer: h.get('referer') };
}

/** The country Cloudflare saw for this request (two letters), or null (locally, or a Tor exit: XX/T1). */
export async function requestCountry(): Promise<string | null> {
  const c = ((await headers()).get('cf-ipcountry') ?? '').toUpperCase();
  return /^[A-Z]{2}$/.test(c) && c !== 'XX' ? c : null;
}
