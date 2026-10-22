// Live visitors (migration 0060): what the Worker entry (custom-worker.ts) and the app's own route (/api/t) both do
// with a beacon before the one database call. No imports: it runs in the Worker entry and in Node.

/** Crawlers, link previews, monitors and scripts. Headless browsers too, unless allowed (the local end-to-end tests). */
const BOT = /bot\b|bot\/|crawl|spider|slurp|mediapartners|facebookexternalhit|embedly|quora link|outbrain|pinterest\/|preview|vkshare|w3c_validator|whatsapp|telegram|discord|skype|lighthouse|pagespeed|gtmetrix|pingdom|uptime|monitor|curl\/|wget\/|python-|python\/|axios\/|node-fetch|go-http-client|java\/|okhttp|libwww|httpclient|scrapy|phantomjs/i;
export function isBot(ua: string | null | undefined, allowHeadless = false): boolean {
  if (!ua || ua.length < 20) return true;
  if (BOT.test(ua)) return true;
  if (!allowHeadless && /HeadlessChrome|Headless/i.test(ua)) return true;
  return false;
}

export function deviceOf(ua: string | null | undefined): 'phone' | 'tablet' | 'desktop' {
  const u = ua ?? '';
  if (/iPad|Tablet|Nexus 7|Nexus 10|SM-T\d|Kindle|Silk/i.test(u) || (/Android/i.test(u) && !/Mobile/i.test(u))) return 'tablet';
  if (/Mobi|iPhone|iPod|Android.*Mobile|Windows Phone/i.test(u)) return 'phone';
  return 'desktop';
}

export interface Beacon {
  sid: string; vid: string; consent: 'analytics' | 'essential'; device?: string; ref?: string; landing?: string;
  utm?: Record<string, string>; ad?: '1';
  /** 0103: the last batch of the page (pagehide): the session ends after its events are stored. Not sent to the database. */
  end?: '1';
  events: Array<{ k: string; path?: string; slug?: string; bn?: string; m?: string; ms?: number; d?: Record<string, string> }>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const KINDS = new Set(['page_view', 'page_leave', 'search', 'request_started', 'request_abandoned', 'email_link_opened', 'pay_left', 'chat_opened',
  // 0086 (analytics consent only; the database checks each detail against its own short list again)
  'quote_seen', 'request_step', 'help_open', 'contact_click', 'photos', 'browse', 'friction']);
/** The details an event may carry: dates, the price shown, a form step, a question's topic, how they contacted us, photos
 *  looked through, a sort or filter, a form error. Never anything a visitor types. */
const DETAIL = ['pickup', 'return', 'days', 'total', 'avail', 'deliv', 'xdrv', 'step', 'topic', 'via', 'n', 'sort', 'filter', 'maxp', 'type'] as const;
const str = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : undefined);

/** The batch as the database expects it, or null when it is not one. Strings are cut short; unknown keys dropped. */
export function cleanBeacon(raw: unknown, ua: string | null): Beacon | null {
  if (!raw || typeof raw !== 'object') return null;
  const b = raw as Record<string, unknown>;
  if (typeof b.sid !== 'string' || !UUID.test(b.sid) || typeof b.vid !== 'string' || !UUID.test(b.vid)) return null;
  const events = Array.isArray(b.events) ? b.events.slice(0, 30) : [];
  const out: Beacon = {
    sid: b.sid, vid: b.vid, consent: b.consent === 'analytics' ? 'analytics' : 'essential', device: deviceOf(ua),
    ref: str(b.ref, 120), landing: str(b.landing, 300), events: []
  };
  if (b.ad === '1' || b.ad === 1 || b.ad === true) out.ad = '1';
  if (b.end === '1' || b.end === 1 || b.end === true) out.end = '1';
  if (b.utm && typeof b.utm === 'object') {
    out.utm = {};
    for (const k of ['source', 'medium', 'campaign', 'term', 'content']) { const v = str((b.utm as Record<string, unknown>)[k], 120); if (v) out.utm[k] = v; }
  }
  for (const e of events) {
    if (!e || typeof e !== 'object') continue;
    const x = e as Record<string, unknown>;
    if (typeof x.k !== 'string' || !KINDS.has(x.k)) continue;
    const d = x.d && typeof x.d === 'object' ? x.d as Record<string, unknown> : null;
    let dd: Record<string, string> | undefined;
    if (d) {
      dd = {};
      for (const k of DETAIL) { const v = typeof d[k] === 'number' ? String(d[k]) : str(d[k], 16); if (v) dd[k] = v; }
    }
    out.events.push({
      k: x.k, path: str(x.path, 300), slug: str(x.slug, 120), bn: str(x.bn, 30), m: str(x.m, 36),
      ms: typeof x.ms === 'number' && x.ms >= 0 ? Math.min(Math.round(x.ms), 86_400_000) : undefined,
      d: dd
    });
  }
  return out;
}

/** 0103: the heartbeat of an open page, {beat: 1, sid, vid, path?, end?}: one cheap UPDATE of the session (app.track_beat),
 *  no event and no signals. `end` (pagehide) marks the session ended. */
export interface Beat { sid: string; vid: string; path?: string; end?: '1' }
export function isBeat(raw: unknown): boolean {
  return Boolean(raw && typeof raw === 'object' && ((raw as Record<string, unknown>).beat === 1 || (raw as Record<string, unknown>).beat === '1'));
}
export function cleanBeat(raw: unknown): Beat | null {
  if (!isBeat(raw)) return null;
  const b = raw as Record<string, unknown>;
  if (typeof b.sid !== 'string' || !UUID.test(b.sid) || typeof b.vid !== 'string' || !UUID.test(b.vid)) return null;
  const out: Beat = { sid: b.sid, vid: b.vid };
  const path = str(b.path, 300);
  if (path && path.startsWith('/')) out.path = path.split('?')[0];
  if (b.end === '1' || b.end === 1 || b.end === true) out.end = '1';
  return out;
}

/** 0103: how long /api/t waits for the database before it answers anyway. The call itself carries on in the
 *  background (waitUntil), so a slow database costs the visitor nothing and never shows as a 502. */
export const BEACON_WAIT_MS = 2_000;
export const BEAT_WAIT_MS = 1_500;
/** The background call gives up after this long (the Worker's waitUntil allows 30 seconds). */
export const BEACON_GIVE_UP_MS = 10_000;
/** The promise's value, or undefined when it takes longer than `ms` or fails. The promise is not cancelled. */
export function within<T>(p: Promise<T>, ms: number): Promise<T | undefined> {
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(undefined), ms);
    p.then((v) => { clearTimeout(t); resolve(v); }, () => { clearTimeout(t); resolve(undefined); });
  });
}

/** A short key for the rate limit only (a day's salt): the network address itself is never sent to the database. */
export async function ipKey(ip: string | null, salt: string): Promise<string | null> {
  if (!ip) return null;
  const day = new Date().toISOString().slice(0, 10);
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${salt}|${day}|${ip}`)));
  return Array.from(h.slice(0, 8), (x) => x.toString(16).padStart(2, '0')).join('');
}

export const MAX_BEACON_BYTES = 16_384;

/** An email link into the renter portal (?m=<outbox row>) may meet a sign-in redirect that drops the query: the Worker
 *  entry (and the local server) keep the id for an hour in a first-party cookie the beacon reads once. */
export function emailLinkCookie(url: string, secure: boolean): string | null {
  const u = new URL(url);
  const m = u.searchParams.get('m');
  if (!/^\/account\/bookings\//.test(u.pathname) || !m || !UUID.test(m)) return null;
  return `cc_m=${m}; Path=/; Max-Age=3600; SameSite=Lax${secure ? '; Secure' : ''}`;
}
