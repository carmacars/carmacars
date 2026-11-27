const HOST = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:\d{1,5})?$/i;
const LOCAL = /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i;

/** The public origin from the forwarded headers, else the configured site address. A localhost host is refused when the
 *  configured address is a real site. */
export function pickOrigin(forwardedHost: string | null, forwardedProto: string | null, configured: string): string {
  const site = new URL(configured);
  const host = (forwardedHost ?? '').split(',')[0]?.trim() ?? '';
  const proto = (forwardedProto ?? '').split(',')[0]?.trim() ?? '';
  if (host && HOST.test(host) && (proto === 'https' || proto === 'http') && !(LOCAL.test(host) && !LOCAL.test(site.host))) return `${proto}://${host}`;
  return site.origin;
}
