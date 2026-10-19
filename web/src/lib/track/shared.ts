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
  utm?: Record<string, string>;
  events: Array<{ k: string; path?: string; slug?: string; bn?: string; m?: string; ms?: number; d?: Record<string, string> }>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const KINDS = new Set(['page_view', 'page_leave', 'search', 'request_started', 'request_abandoned', 'email_link_opened', 'pay_left', 'chat_opened']);
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
  if (b.utm && typeof b.utm === 'object') {
    out.utm = {};
    for (const k of ['source', 'medium', 'campaign', 'term', 'content']) { const v = str((b.utm as Record<string, unknown>)[k], 120); if (v) out.utm[k] = v; }
  }
  for (const e of events) {
    if (!e || typeof e !== 'object') continue;
    const x = e as Record<string, unknown>;
    if (typeof x.k !== 'string' || !KINDS.has(x.k)) continue;
    const d = x.d && typeof x.d === 'object' ? x.d as Record<string, unknown> : null;
    out.events.push({
      k: x.k, path: str(x.path, 300), slug: str(x.slug, 120), bn: str(x.bn, 30), m: str(x.m, 36),
      ms: typeof x.ms === 'number' && x.ms >= 0 ? Math.min(Math.round(x.ms), 86_400_000) : undefined,
      d: d ? { pickup: str(d.pickup, 16) ?? '', return: str(d.return, 16) ?? '' } : undefined
    });
  }
  return out;
}

/** A short key for the rate limit only (a day's salt): the network address itself is never sent to the database. */
export async function ipKey(ip: string | null, salt: string): Promise<string | null> {
  if (!ip) return null;
  const day = new Date().toISOString().slice(0, 10);
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${salt}|${day}|${ip}`)));
  return Array.from(h.slice(0, 8), (x) => x.toString(16).padStart(2, '0')).join('');
}

export const MAX_BEACON_BYTES = 16_384;
