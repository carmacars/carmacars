import 'server-only';
import { headers } from 'next/headers';

// Who is asking: the address Cloudflare saw (CF-Connecting-IP), else the proxy chain; the browser;
// and a request id for the audit log (docs/blueprint/00-overview.md section 2.3, step 7).
export async function requestMeta() {
  const h = await headers();
  const ip = h.get('cf-connecting-ip') ?? h.get('x-forwarded-for')?.split(',')[0]?.trim() ?? h.get('x-real-ip') ?? null;
  return { ip: ip && /^[0-9a-f:.]+$/i.test(ip) ? ip : null, userAgent: (h.get('user-agent') ?? '').slice(0, 300), requestId: h.get('cf-ray') ?? crypto.randomUUID(), referer: h.get('referer') };
}
