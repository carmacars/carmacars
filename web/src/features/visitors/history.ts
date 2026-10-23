// Visitor history (migration 0118): the shapes of the two Admin reads, the filters of the list as they travel in the
// address, and the words and the chart model of the pages. No imports, so the unit tests run it as it is.

export type Conversion = 'request' | 'booking' | 'signup' | 'contact';
export interface HistoryRow {
  id: string; who: string; known: boolean; renter_id: string | null; started_at: string; last_seen_at: string; duration_s: number;
  device: string | null; city: string | null; region: string | null; country: string | null; consent: string;
  source: string; referrer: string | null; utm_source: string | null; utm_medium: string | null; utm_campaign: string | null; from_ad: boolean;
  landing_path: string | null; landing: string | null; exit_path: string | null; exit: string | null;
  page_views: number; cars_viewed: number; visit_number: number; returning: boolean; conversions: Conversion[]; has_contact: boolean;
  exclude_reason: 'bot' | 'staff' | null; summarized: boolean;
}
export interface DayFigure { day: string; visits: number; visitors: number; converted: number; page_views: number }
export interface TopRow { key: string; label?: string | null; n: number }
export interface Summary {
  days: DayFigure[];
  totals: { visits: number; visitor_days: number; new_visits: number; returning_visits: number; known_visits: number; page_views: number; bounces: number; seconds: number;
    converted: number; requests: number; bookings: number; signups: number; contacts: number; phone: number; tablet: number; desktop: number; left_out: number };
  visitors: number | null; computed_at: string | null;
  top: { page: TopRow[]; source: TopRow[]; landing: TopRow[]; country: TopRow[] };
}
export interface HistoryData {
  rows: HistoryRow[]; next: string | null; from: string; to: string; oldest: string; limit: number; filtered: boolean;
  keep: { visits_days: number; pages_days: number; daily_days: number }; summary?: Summary;
}
export interface TimelineItem { at: string; kind: string; path: string | null; page: string | null; is_page: boolean; car: string | null; booking_number: string | null;
  pickup: string | null; return: string | null; detail: string | null; seconds: number | null }
export interface VisitDetail extends HistoryRow {
  email: string | null; identified_by: string | null; assigned: string | null; score: number | null; pages_kept: boolean; pages_keep_days: number;
  timeline: TimelineItem[];
  games: Array<{ game: string; at: string; trigger: string | null; prize: string | null; revealed_at: string | null; claimed_at: string | null; code: string | null }>;
  chats: Array<{ id: string; number: string; status: string; at: string; messages: number; first: Array<{ at: string; sender: string; body: string }> }>;
  forms: Array<{ form: string; first_at: string; last_at: string; sent: boolean; done_reason: string | null; name: string | null; email: string | null; phone: string | null; lead_id: string | null; renter_id: string | null }>;
  bookings: Array<{ number: string; status: string; requested_at: string; booked_at: string | null }>;
  renter: { id: string; name: string } | null; signed_in: boolean;
  other_visits: { count: number; recent: Array<{ id: string; started_at: string; page_views: number; conversions: Conversion[] }> };
}

/** The list's filters, in the order the form shows them. Anything else in the address is ignored. */
export const FILTER_KEYS = ['from', 'to', 'source', 'landing', 'device', 'country', 'city', 'visitor', 'converted', 'contact', 'known', 'bots'] as const;
export type FilterKey = (typeof FILTER_KEYS)[number];
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const CHOICES: Partial<Record<FilterKey, readonly string[]>> = {
  device: ['phone', 'tablet', 'desktop'], visitor: ['new', 'returning'], converted: ['any', 'none', 'request', 'booking', 'signup', 'contact'],
  contact: ['1'], known: ['1'], bots: ['1']
};
const MAX: Partial<Record<FilterKey, number>> = { source: 120, landing: 300, city: 80 };

/** The filters from the address, checked: dates as YYYY-MM-DD, choices from their lists, text trimmed and capped. */
export function historyFilters(sp: Record<string, string | string[] | undefined>): Partial<Record<FilterKey, string>> {
  const out: Partial<Record<FilterKey, string>> = {};
  for (const k of FILTER_KEYS) {
    const raw = sp[k];
    const v = (Array.isArray(raw) ? raw[0] : raw)?.trim();
    if (!v) continue;
    if (k === 'from' || k === 'to') { if (DAY.test(v)) out[k] = v; continue; }
    const choices = CHOICES[k];
    if (choices) { if (choices.includes(v)) out[k] = v; continue; }
    if (k === 'country') { if (/^[A-Za-z]{2}$/.test(v)) out[k] = v; continue; }
    out[k] = v.slice(0, MAX[k] ?? 120);
  }
  return out;
}

/** The read's parameters: the filters, and the cursor of the page when there is one. */
export function historyParams(sp: Record<string, string | string[] | undefined>): Record<string, string> {
  const p: Record<string, string> = { ...historyFilters(sp) };
  const c = Array.isArray(sp.cursor) ? sp.cursor[0] : sp.cursor;
  if (c && /^[0-9T:. +-]{19,40}\|[0-9a-f-]{36}$/.test(c)) p.cursor = c;
  return p;
}

/** The list's address with these filters (and a cursor, for the next page). */
export function historyHref(f: Partial<Record<FilterKey, string>>, cursor?: string | null): string {
  const q = new URLSearchParams();
  for (const k of FILTER_KEYS) if (f[k]) q.set(k, f[k]!);
  if (cursor) q.set('cursor', cursor);
  const s = q.toString();
  return s ? `/admin/live/history?${s}` : '/admin/live/history';
}

export const CONVERSION_WORDS: Record<Conversion, string> = { request: 'Request sent', booking: 'Booking confirmed', signup: 'Account opened', contact: 'Contact details given' };
export const DEVICE_WORDS: Record<string, string> = { phone: 'Phone', tablet: 'Tablet', desktop: 'Computer' };
export const EVENT_WORDS: Record<string, string> = {
  page_view: 'Viewed', car_view: 'Opened a car', search: 'Searched dates', request_started: 'Started a booking request', request_abandoned: 'Left the request form',
  request_submitted: 'Sent a booking request', email_link_opened: 'Opened an email link', offer_viewed: 'Viewed the offer', change_viewed: 'Viewed the change proposal',
  pay_viewed: 'Viewed the pay page', pay_left: 'Left the pay page', chat_opened: 'Opened the chat', quote_seen: 'Saw the price', request_step: 'Reached a step of the request form',
  help_open: 'Opened a question', contact_click: 'Tapped to contact us', photos: 'Looked through photos', browse: 'Sorted or filtered the cars', friction: 'Had trouble with a form'
};

/** "45 s", "3 min 20 s", "1 h 5 min". */
export function duration(seconds: number | null | undefined): string {
  const s = Math.max(0, Math.round(Number(seconds) || 0));
  if (s < 60) return `${s} s`;
  if (s < 3600) { const m = Math.floor(s / 60), r = s % 60; return r ? `${m} min ${r} s` : `${m} min`; }
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  return m ? `${h} h ${m} min` : `${h} h`;
}

/** Where the visit came from, in words: the campaign (source / medium, campaign), the referring site, direct. */
export function sourceWords(r: Pick<HistoryRow, 'source' | 'utm_source' | 'utm_medium' | 'utm_campaign' | 'from_ad' | 'consent'>): string {
  let s: string;
  if (r.utm_source) s = [r.utm_source, r.utm_medium].filter(Boolean).join(' / ') + (r.utm_campaign ? `, ${r.utm_campaign}` : '');
  else if (r.source === 'direct') s = 'Direct';
  else if (r.source === 'not recorded') s = 'Not recorded (necessary cookies only)';
  else s = r.source;
  return r.from_ad ? `${s} (ad)` : s;
}
export const topSourceWords = (key: string) => (key === 'direct' ? 'Direct' : key === 'not recorded' ? 'Not recorded' : key);

/** "Ottawa, ON, CA"; "" when nothing is known. */
export const place = (r: Pick<HistoryRow, 'city' | 'region' | 'country'>) => [r.city, r.region, r.country].filter(Boolean).join(', ');

/** A share in words: "12.5%"; "" without a base. */
export const pct = (n: number, of: number) => (of > 0 ? `${(Math.round((n * 1000) / of) / 10).toLocaleString('en-US')}%` : '');

/** A time of day in Toronto with seconds, for the timeline. */
export const clockS = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit', second: '2-digit', timeZone: 'America/Toronto' });

/** The chart: one bar per day (visits), the conversions inside it, the unique visitors as a line; peaks for the label. */
export function chartModel(days: DayFigure[], W = 600, H = 120) {
  const max = Math.max(1, ...days.map((d) => d.visits));
  const n = Math.max(1, days.length);
  const bw = W / n;
  const y = (v: number) => H - (v / max) * (H - 4);
  const bars = days.map((d, i) => ({ day: d.day, x: i * bw + Math.min(1, bw * 0.1), w: Math.max(0.5, bw - Math.min(2, bw * 0.2)), y: y(d.visits), h: H - y(d.visits), cy: y(d.converted), ch: H - y(d.converted) }));
  const line = days.map((d, i) => `${(i * bw + bw / 2).toFixed(1)},${y(d.visitors).toFixed(1)}`).join(' ');
  const peak = days.reduce<DayFigure | null>((a, b) => (!a || b.visits > a.visits ? b : a), null);
  return { W, H, max, bars, line, peak };
}
