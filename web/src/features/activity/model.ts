// The renter's Activity log (migration 0850, release 35): one time-ordered log of everything about a renter or a booking
// (emails, texts, live chat, calls with their summaries, notes, booking events, payments, documents, the website), with a
// filter chip per type and a search. The page reads it through one server read (renter_activity), 50 a page, Older for
// the next. Pure: the log, the pages and the unit tests share it.

export const ACTIVITY_TYPES = ['email', 'text', 'chat', 'call', 'note', 'booking', 'payment', 'document', 'visit'] as const;
export type ActivityType = (typeof ACTIVITY_TYPES)[number];

/** The chip of each type. */
export const TYPE_LABEL: Record<ActivityType, string> = {
  email: 'Emails', text: 'Texts', chat: 'Live chat', call: 'Calls', note: 'Notes', booking: 'Booking', payment: 'Payments', document: 'Documents and ID', visit: 'Website'
};

export interface ActivityItem {
  k: string; type: ActivityType; at: string; title: string; body: string | null; dir: 'in' | 'out' | null; by: string | null;
  booking_number: string | null; ref: string | null;
  extra: { missed?: boolean; duration?: number | null; summary_by?: 'quo' | 'ai' | null; next_steps?: string[] | null; status?: string; cents?: number; chat?: string; role?: string; visit_number?: number } | null;
}
export interface ActivityPage { renter_id: string | null; booking: string | null; types: ActivityType[]; items: ActivityItem[]; more: boolean; next: { before: string; before_k: string } | null }

/** The URL parameters of the log (kept apart from the page's own: q, tab, id and booking stay as they are). */
export const P = { type: 'act', q: 'aq', before: 'before', k: 'bk' } as const;

export interface ActivityQuery { type: ActivityType | null; q: string; before: string | null; k: string | null }

/** The log's query from the page's search parameters; anything unknown is ignored. */
export function activityQuery(sp: Record<string, string | undefined>): ActivityQuery {
  const t = sp[P.type];
  const before = sp[P.before] && !Number.isNaN(Date.parse(sp[P.before]!)) ? sp[P.before]! : null;
  return { type: (ACTIVITY_TYPES as readonly string[]).includes(t ?? '') ? (t as ActivityType) : null, q: (sp[P.q] ?? '').trim().slice(0, 100), before, k: before ? (sp[P.k] ?? '').slice(0, 80) : null };
}

/** What the server read is asked for. */
export function readParams(q: ActivityQuery): Record<string, string> {
  return { ...(q.type ? { types: q.type } : {}), ...(q.q ? { q: q.q } : {}), ...(q.before ? { before: q.before, before_k: q.k ?? '' } : {}) };
}

/** A link on the page with the log's parameters changed (null removes one). The base's own parameters (the booking page's
 * tab) win, the page's other parameters stay, and the link lands on the log. */
export function logHref(base: string, sp: Record<string, string | undefined>, change: Partial<Record<keyof typeof P, string | null>>): string {
  const [path, qs = ''] = base.split('?');
  const u = new URLSearchParams(qs);
  const own = new Set<string>(Object.values(P));
  for (const [k, v] of Object.entries(sp)) if (v && !own.has(k) && !u.has(k)) u.set(k, v);
  const cur = activityQuery(sp);
  const next: Record<keyof typeof P, string | null> = { type: cur.type, q: cur.q || null, before: cur.before, k: cur.k };
  // a new filter or search starts from the newest
  if ('type' in change || 'q' in change) { next.before = null; next.k = null; }
  Object.assign(next, change);
  for (const key of Object.keys(P) as Array<keyof typeof P>) if (next[key]) u.set(P[key], next[key]!);
  const s = u.toString();
  return `${path}${s ? `?${s}` : ''}#activity`;
}

/** The hidden fields of the search form: the base's parameters and the page's, but not the log's search and cursor. */
export function hiddenFields(base: string, sp: Record<string, string | undefined>): Array<[string, string]> {
  const out = new Map<string, string>(new URLSearchParams(base.split('?')[1] ?? ''));
  const skip = new Set<string>([P.q, P.before, P.k]);
  for (const [k, v] of Object.entries(sp)) if (v && !skip.has(k) && !out.has(k)) out.set(k, v);
  return [...out];
}

const mins = (s: number) => (s < 60 ? `${s} s` : `${Math.round(s / 60)} min`);

/** The small line under an item's title: who, the booking, how long a call was. */
export function itemMeta(i: ActivityItem): string {
  return [i.by, i.booking_number, i.type === 'call' && !i.extra?.missed && i.extra?.duration ? mins(i.extra.duration) : null,
    i.type === 'call' && i.extra?.summary_by === 'ai' && i.body ? 'summary by AI' : null].filter(Boolean).join(' · ');
}

/** The action of an item, when it has one: reply to an email, text back, call back, open the chat or the visit. */
export type ItemAction = { kind: 'reply'; href: string } | { kind: 'text' } | { kind: 'call' } | { kind: 'link'; label: string; href: string };
export function itemAction(i: ActivityItem, o: { emailHref: string | null; chatBase: string | null; inbox: string | null }): ItemAction | null {
  if (i.type === 'email' && i.dir === 'in' && o.emailHref) return { kind: 'reply', href: o.emailHref };
  if (i.type === 'text' && i.dir === 'in') return { kind: 'text' };
  if (i.type === 'call' && (i.dir === 'in' || i.extra?.missed)) return { kind: 'call' };
  if (i.type === 'chat' && i.ref && o.chatBase) return { kind: 'link', label: 'Open the chat', href: `${o.chatBase}${o.chatBase.includes('?') ? '&' : '?'}id=${encodeURIComponent(i.ref)}` };
  if ((i.type === 'text' || i.type === 'call') && i.ref && o.inbox) return { kind: 'link', label: 'Open the conversation', href: `${o.inbox}${o.inbox.includes('?') ? '&' : '?'}inbox=phone&id=${encodeURIComponent(i.ref)}` };
  return null;
}

/** Items grouped by their day in Toronto (the log's headings), in order. */
export function byDay(items: ActivityItem[]): Array<{ day: string; items: ActivityItem[] }> {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
  const out: Array<{ day: string; items: ActivityItem[] }> = [];
  for (const i of items) {
    const d = f.format(new Date(i.at));
    const last = out[out.length - 1];
    if (last && last.day === d) last.items.push(i); else out.push({ day: d, items: [i] });
  }
  return out;
}
