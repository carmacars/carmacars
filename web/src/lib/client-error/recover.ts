// What a crashed page does by itself (hotfix r27b, 2026-11-06). The owner's "Something went wrong" pages of November 6
// (16:01 to 16:04 UTC: /admin, /admin/requests, /sign-in) were React error 441, a server render that failed while the
// database was swamped by a scraper; the button "Reload the page" fixed each. A page of an older deploy (a tab left
// open: a server action or a script of the previous build) fails the same way. Both are reloaded once, by themselves,
// at most once a minute per tab (sessionStorage), so a real outage never loops. No imports: unit tested in Node.

export const RECOVER_KEY = 'cc-error-reload';
/** A page of an older deploy: a server action, a script or a stylesheet the new build does not have. */
export const STALE_BUILD = /Failed to find Server Action|Server Action .* was not found|older or newer deployment|ChunkLoadError|Loading (CSS )?chunk|Failed to fetch dynamically imported module|Importing a module script failed|error loading dynamically imported module|An unexpected response was received from the server/i;
/** The server could not finish the page (React 441 in production, or the network dropped the answer). */
export const SERVER_RENDER = /Minified React error #441|Server Components render|Failed to fetch|NetworkError|Load failed|Connection closed/i;

export type Recovery = 'reload' | 'none';
/** Whether this crash is one a reload fixes, given when this tab last reloaded for one (ms, 0 for never). */
export function recoveryFor(e: { message?: string; digest?: string } | null | undefined, lastReloadAt: number, now: number): Recovery {
  const m = String(e?.message ?? '');
  if (!(STALE_BUILD.test(m) || SERVER_RENDER.test(m) || (!!e?.digest && /omitted in production|#441/.test(m)))) return 'none';
  return now - lastReloadAt < 60_000 ? 'none' : 'reload';
}

/** In the browser: reload the page once (fresh) when the crash is one a reload fixes; true when it is reloading. */
export function recoverInBrowser(e: { message?: string; digest?: string }): boolean {
  if (typeof window === 'undefined') return false;
  let last = 0;
  try { last = Number(window.sessionStorage.getItem(RECOVER_KEY)) || 0; } catch { /* private mode: once per page */ }
  if (recoveryFor(e, last, Date.now()) !== 'reload') return false;
  try { window.sessionStorage.setItem(RECOVER_KEY, String(Date.now())); } catch { /* nothing kept */ }
  window.setTimeout(() => window.location.reload(), 1200);
  return true;
}

// ------------------------------------------------------------------ what the page says (r27b, the owner: "Try again and Reload
// just fail again, and it says call or text us with no number")
/** The server could not answer (busy, a gateway timeout, the network dropped it): not the device's fault. */
export const SERVER_BUSY = /Minified React error #441|Server Components render|error code: 5\d\d|\b50[234]\b|did not answer|too slow|busy|timed? ?out|Failed to fetch|NetworkError|Load failed|Connection closed|An unexpected response was received/i;
export type Cause = 'server' | 'stale' | 'device';
export function causeOf(e: { message?: string; digest?: string } | null | undefined): Cause {
  const m = String(e?.message ?? '');
  if (STALE_BUILD.test(m)) return 'stale';
  if (SERVER_BUSY.test(m) || (!!e?.digest && /omitted in production/.test(m))) return 'server';
  return 'device';
}
/** Seconds before the next automatic try: 5, 10, 20, 40, then every 60. */
export function retryDelayS(attempt: number): number {
  return Math.min(60, 5 * 2 ** Math.max(0, attempt));
}
export const FALLBACK_CONTACT = { phone: '289-312-5991', email: 'contact@carmacars.ca' };
/** The site's phone and email, from the page's meta tag (the layout writes it from Site settings), else the defaults. */
export function readContact(doc: { querySelector(s: string): { getAttribute(n: string): string | null } | null } | null | undefined): { phone: string; email: string } {
  try {
    const raw = doc?.querySelector('meta[name="cc-contact"]')?.getAttribute('content');
    const c = raw ? (JSON.parse(raw) as { phone?: string | null; email?: string | null }) : {};
    return { phone: c.phone || FALLBACK_CONTACT.phone, email: c.email || FALLBACK_CONTACT.email };
  } catch { return { ...FALLBACK_CONTACT }; }
}
/** tel: and sms: addresses for a North American number as people write it. */
export function dialable(phone: string): string {
  const d = phone.replace(/[^0-9+]/g, '');
  return /^\+/.test(d) ? d : d.length === 10 ? `+1${d}` : d.length === 11 && d.startsWith('1') ? `+${d}` : d;
}
