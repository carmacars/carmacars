// Where a link opens in the app: a universal link or app link to carmacars.ca, a tapped alert's page, or where a server
// action says the site would go next. Pages the app has natively open as screens; every other page of the site (the
// Admin portal's long tail, guides, terms) opens in the in-app browser. No imports.
export type Target = { kind: 'screen'; href: string } | { kind: 'web'; path: string } | null;

const HOSTS = ['carmacars.ca', 'www.carmacars.ca'];
const NUMBER = '[A-Za-z]{1,4}-[0-9A-Za-z]{1,12}';
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const TRIP_PAGES: Record<string, string> = { checkout: 'sign', sign: 'sign', pay: 'pay', verify: 'verify', pickup: 'checkin', returned: 'checkout', extend: 'extend' };

/** A path of the site from a link, or null for anything else (another site, a script URL, a path with odd characters). */
export function sitePath(raw: string | null | undefined, hosts: readonly string[] = HOSTS): string | null {
  const s = (raw ?? '').trim();
  if (!s) return null;
  let p: string;
  if (s.startsWith('/') && !s.startsWith('//') && !s.startsWith('/\\')) p = s;
  else if (/^carmacars:\/\//i.test(s)) p = '/' + s.replace(/^carmacars:\/\/\/?/i, '');
  else {
    const m = /^https:\/\/([^/?#@:]+)(\/[^\s]*)?$/i.exec(s);
    if (!m || !hosts.includes(m[1]!.toLowerCase())) return null;
    p = m[2] ?? '/';
  }
  return /^\/[^\\\s]*$/.test(p) && !/[\u0000-\u001f]/.test(p) ? p : null;
}

/** The screen for a path of the site, or the in-app browser. */
export function targetFor(raw: string | null | undefined, hosts?: readonly string[]): Target {
  const full = sitePath(raw, hosts);
  if (!full) return null;
  const path = (full.split(/[?#]/)[0] ?? '/').replace(/\/+$/, '') || '/';
  const hash = full.includes('#') ? full.slice(full.indexOf('#') + 1) : '';
  let m: RegExpExecArray | null;
  if (path === '/' || path === '/app' || path === '/cars') return { kind: 'screen', href: '/' };
  if ((m = new RegExp(`^/cars/([a-z0-9-]{1,120})$`).exec(path))) return { kind: 'screen', href: `/car/${m[1]}` };
  if (path === '/account' || path === '/account/bookings') return { kind: 'screen', href: '/trips' };
  if ((m = new RegExp(`^/account/bookings/(${NUMBER})(?:/([a-z-]+))?$`).exec(path))) {
    const n = m[1]!.toUpperCase();
    const sub = m[2];
    if (!sub) return { kind: 'screen', href: `/trip/${n}` };
    // Sign and pay is one page on the site (#pay after signing); two screens here
    if (sub === 'checkout' && hash === 'pay') return { kind: 'screen', href: `/trip/${n}/pay` };
    return TRIP_PAGES[sub] ? { kind: 'screen', href: `/trip/${n}/${TRIP_PAGES[sub]}` } : { kind: 'web', path: full };
  }
  // the alerts settings are in the app's Profile; the profile's own details (address, licence) are edited on the site
  if (path === '/account/notifications') return { kind: 'screen', href: '/profile' };
  if (path === '/staff/field' || path === '/staff/field/today') return { kind: 'screen', href: '/field' };
  if (path === '/staff/field/shifts') return { kind: 'screen', href: '/field/shifts' };
  if ((m = new RegExp(`^/staff/field/jobs/(${UUID})$`).exec(path))) return { kind: 'screen', href: `/field/job/${m[1]}` };
  if (path === '/staff/sales-leads' || path === '/staff/leads') return { kind: 'screen', href: '/leads' };
  if ((m = new RegExp(`^/staff/sales-leads/(${UUID})$`).exec(path))) return { kind: 'screen', href: `/sales/lead/${m[1]}` };
  if (path === '/owner') return { kind: 'screen', href: '/owner' };
  if (path === '/owner/bookings') return { kind: 'screen', href: '/owner/bookings' };
  if ((m = /^\/owner\/statements\/([0-9A-Za-z-]{1,40})$/.exec(path))) return { kind: 'screen', href: `/owner/statement/${m[1]}` };
  if (path === '/sign-in') return { kind: 'screen', href: '/sign-in' };
  return { kind: 'web', path: full };
}
