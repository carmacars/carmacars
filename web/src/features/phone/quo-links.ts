// Call and Text through Quo (r27 consolidation, migration 0500). No imports, so the unit tests run it as it is.
//
// Quo (formerly OpenPhone) documents these (support.quo.com, "Deep linking" and "Click to call", November 2026):
//   openphone://dial?number=<number>&from=<our number>            the dialer with the number (add &action=call to dial at once)
//   openphone://message?number=<number>&from=<our number>&text=   the composer
// Deep links work in the Quo phone apps only. On a computer, Quo's desktop app answers tel: links once it is the default
// calling app (Windows: TEL protocol; Mac: FaceTime > Default for calls), and the web app (https://my.quo.com/inbox/)
// has no address for a number: its dialer opens with Alt+C (Ctrl+C on a Mac), where the copied number is pasted.

export const QUO_WEB = 'https://my.quo.com/inbox/';
/** On this computer: open calls in the Quo web app (default) or the Quo desktop app (through tel:). */
export const QUO_DESKTOP_KEY = 'carmacars.quo.desktop';

/** A Canadian or US number typed any way, as +1..., or null when it is not one we can call. */
export function e164(phone: string | null | undefined): string | null {
  const raw = (phone ?? '').trim();
  const d = raw.replace(/\D/g, '');
  if (d.length === 10 && /^[2-9]/.test(d)) return `+1${d}`;
  if (d.length === 11 && d.startsWith('1')) return `+${d}`;
  if (raw.startsWith('+') && d.length >= 8 && d.length <= 15) return `+${d}`;
  return null;
}

/** The device's own phone and messages apps: the fallback when Quo is off. */
export const telHref = (n: string) => `tel:${n}`;
export const smsHref = (n: string) => `sms:${n}`;

/** Quo's phone app: the dialer with the number, calling from the CarmaCars number when it is known. */
export function quoDial(n: string, from?: string | null): string {
  const q = new URLSearchParams({ number: n });
  if (from) q.set('from', from);
  return `openphone://dial?${q.toString()}`;
}
/** Quo's phone app: the composer to the number. */
export function quoMessage(n: string, from?: string | null, text?: string): string {
  const q = new URLSearchParams({ number: n });
  if (from) q.set('from', from);
  if (text) q.set('text', text);
  return `openphone://message?${q.toString()}`;
}

/** A phone or tablet (where Quo's app links work), from the browser's user agent. */
export function isHandheld(ua: string): boolean {
  return /Android|iPhone|iPad|iPod|Mobile/i.test(ua);
}

export type CallPlan = { kind: 'native'; href: string } | { kind: 'quo-app'; href: string } | { kind: 'quo-desktop'; href: string } | { kind: 'quo-web'; href: string };
/** What a Call button does: the device's phone when Quo is off; on a phone the Quo app; on a computer the Quo desktop app
 *  (tel:, when chosen on this computer) or the Quo web app. */
export function callPlan(n: string, o: { quo: boolean; from?: string | null; ua: string; desktop?: string | null }): CallPlan {
  if (!o.quo) return { kind: 'native', href: telHref(n) };
  if (isHandheld(o.ua)) return { kind: 'quo-app', href: quoDial(n, o.from) };
  if (o.desktop === 'app') return { kind: 'quo-desktop', href: telHref(n) };
  return { kind: 'quo-web', href: QUO_WEB };
}

/** "(416) 555-0177" for +14165550177; other numbers as given. */
export function prettyNumber(n: string): string {
  const m = n.match(/^\+1(\d{3})(\d{3})(\d{4})$/);
  return m ? `(${m[1]}) ${m[2]}-${m[3]}` : n;
}
