// The visitor's address for rate limits and audit logs (r48 security audit, docs/security/audit-2026-11-r48.md).
// Production: only CF-Connecting-IP. Cloudflare sets it, and on the company's server Caddy overwrites it with the address
// it saw for any request that did not come from Cloudflare's ranges (infra/vps/web/site.caddy), so a visitor cannot
// choose it. X-Forwarded-For and X-Real-IP are written by the caller and are never read in production.
// With no usable address in production the answer is NO_IP, one shared address: every limit keyed by the address then
// still counts (all such requests share one bucket and are refused early) instead of being skipped (a limit that fails
// open). Outside production (the local stack, the tests) the proxy headers are read and a missing address is null.
export const NO_IP = '0.0.0.0';
const IP = /^[0-9a-f:.]{2,45}$/i;

type Get = (name: string) => string | null | undefined;
const valid = (v: string | null | undefined): string | null => { const s = (v ?? '').trim(); return s && IP.test(s) ? s : null; };

export function clientIp(get: Get, production: boolean): string | null {
  const cf = valid(get('cf-connecting-ip'));
  if (cf) return cf;
  if (production) return NO_IP;
  return valid(get('x-forwarded-for')?.split(',')[0]) ?? valid(get('x-real-ip'));
}
