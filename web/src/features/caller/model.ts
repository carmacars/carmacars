// The caller pop-up and renter notes (migration 0800): the shapes of the caller_live and renter_notes reads, and the words
// the pop-up shows. No imports, so the unit tests run it as is (model.test.ts).

export type Portal = 'admin' | 'va';
export interface CallerNote { id: string; body: string; at: string; author: string; role: 'admin' | 'cs' | 'sales' | 'fleet' | 'finance'; booking_number: string | null; from_call: boolean }
export interface CallerDeposit { required_cents: number; held_cents: number; how: string | null; state: 'held' | 'waived' | 'released' | 'failed' | 'none' | 'not_taken' }
export interface CallerBalance { owed_cents: number; rental_cents: number; charges_cents: number; overdue: boolean }
export interface CallerRequest { kind: 'booking' | 'change' | 'question' | 'task'; label: string; booking_number: string | null; at: string }
export interface CallerRenter {
  id: string; name: string; identity_status: string; is_blocked: boolean;
  booking: { number: string; status: string; car: string | null; pickup_at: string; return_at: string; active: boolean } | null;
  balance: CallerBalance; deposit: CallerDeposit | null; requests: CallerRequest[]; notes: CallerNote[]; notes_count: number;
}
export interface LiveCall {
  id: string; thread_id: string; number: string; display: string; at: string; answered_at: string | null; ended_at: string | null; missed: boolean; live: boolean;
  kind: 'staff' | 'renter' | 'owner' | 'lead' | 'unknown'; who: string; lead_id: string | null; owner_id: string | null; renter: CallerRenter | null;
  /** r35 (0970): fleet when the call is about a pickup, a return, a delivery or a car on rent (it rings for Fleet first) */
  lane?: 'fleet' | 'cs';
}
export interface CallerLive { at: string; calls: LiveCall[] }
export interface NotesRead { renter_id: string; notes: CallerNote[]; can_remove: boolean }

/** How often the portals ask while in use (lib/poll slows it to once a minute when idle, never in a hidden tab). */
export const CALLER_POLL_MS = 10_000;
/** The calls a person closed are remembered (in this browser) for this long. */
export const DISMISS_KEEP_MS = 2 * 60 * 60_000;

export const money = (cents: number | null | undefined) =>
  `$${((cents ?? 0) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export const ROLE_WORDS: Record<CallerNote['role'], string> = { admin: 'Admin', cs: 'Customer service', sales: 'Sales', fleet: 'Fleet', finance: 'Finance' };

/** The calls to show: those not closed by this person, newest first. */
export function visibleCalls(calls: LiveCall[], dismissed: Record<string, number>): LiveCall[] {
  return calls.filter((c) => !(c.id in dismissed)).sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
}

/** Closed calls older than the keep time are forgotten, so the stored list stays small. */
export function pruneDismissed(d: Record<string, number>, now: number): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(d)) if (typeof v === 'number' && now - v < DISMISS_KEEP_MS) out[k] = v;
  return out;
}

/** The headline: who is on the phone. */
export function callerTitle(c: LiveCall): string {
  if (c.kind === 'unknown') return 'Unknown caller';
  if (c.kind === 'renter' && c.renter) return c.renter.name;
  return c.who;
}
export const KIND_WORDS: Record<LiveCall['kind'], string> = { staff: 'Staff', renter: 'Renter', owner: 'Owner', lead: 'Lead', unknown: 'Not matched' };

/** The state of the call in a few words. */
export function callState(c: LiveCall): string {
  if (c.live) return c.answered_at ? 'On the phone now' : 'Ringing now';
  if (c.missed) return 'Missed call';
  return 'Call ended';
}

export function depositWords(d: CallerDeposit | null): string {
  if (!d) return 'No booking';
  switch (d.state) {
    case 'held': return `${money(d.held_cents)} held${d.how === 'card_hold' ? ' on the card' : ''}`;
    case 'waived': return 'Waived';
    case 'released': return 'Released';
    case 'failed': return `Not taken: the card was declined (${money(d.required_cents)} due)`;
    case 'none': return 'None needed';
    default: return `Not taken yet (${money(d.required_cents)})`;
  }
}

export function balanceWords(b: CallerBalance): string {
  if (!b.owed_cents) return 'Nothing owed';
  return `${money(b.owed_cents)} owed${b.overdue ? ', overdue' : ''}`;
}

export function bookingWords(r: CallerRenter): string {
  const b = r.booking;
  if (!b) return 'No active or upcoming booking';
  return `${b.active ? 'On rent' : 'Next'}: ${b.number}${b.car ? `, ${b.car}` : ''}`;
}

/** The renter's full page in the person's portal. */
export function renterHref(portal: Portal, id: string): string {
  return portal === 'admin' ? `/admin/renters/${id}` : `/staff/renters?id=${encodeURIComponent(id)}`;
}
export function bookingHref(portal: Portal, n: string): string {
  return portal === 'admin' ? `/admin/bookings/${encodeURIComponent(n)}` : `/staff/bookings/${encodeURIComponent(n)}`;
}

/** Why a note cannot be saved (null: it can). The database checks the same. */
export function noteProblem(body: string): string | null {
  const s = body.trim();
  if (!s) return 'Write the note';
  if (s.length > 4000) return 'Keep a note under 4,000 characters';
  return null;
}

// ---------------------------------------------------------------- the pop-up minimized (r42, migration 2670)
/** The call's timer: from the answer (the first ring before it) to the end, as 2:05 or 1:02:05. */
export function callTimer(c: Pick<LiveCall, 'at' | 'answered_at' | 'ended_at'>, now: number): string {
  const from = Date.parse(c.answered_at ?? c.at);
  const to = c.ended_at ? Date.parse(c.ended_at) : now;
  const s = Number.isFinite(from) && Number.isFinite(to) ? Math.max(0, Math.floor((to - from) / 1000)) : 0;
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), ss = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}
/** The same for a screen reader: "2 minutes 5 seconds". */
export function callTimerWords(timer: string): string {
  const p = timer.split(':').map(Number);
  const [h, m, s] = p.length === 3 ? [p[0] ?? 0, p[1] ?? 0, p[2] ?? 0] : [0, p[0] ?? 0, p[1] ?? 0];
  const w = (n: number, one: string) => `${n} ${one}${n === 1 ? '' : 's'}`;
  return [h ? w(h, 'hour') : '', h || m ? w(m, 'minute') : '', w(s, 'second')].filter(Boolean).join(' ');
}
/** The calls open as panels and the calls minimized to a chip (each in the order of visibleCalls). */
export function splitCalls(shown: LiveCall[], minimized: Record<string, number>): { open: LiveCall[]; chips: LiveCall[] } {
  return { open: shown.filter((c) => !(c.id in minimized)), chips: shown.filter((c) => c.id in minimized) };
}

// ---------------------------------------------------------------- the Call helper (r42, migration 2670)
export interface HelpSituation { code: string; title: string; steps: string[] }
export interface HelpFaq { code: string; q: string; a: string; keywords: string }
/** The call_helper read: the staff member's first name, the greeting for each kind of caller, the situations and the FAQ. */
export interface CallHelp { staff: string; can_edit: boolean; greetings: Record<string, string>; situations: HelpSituation[]; faq: HelpFaq[] }

/** The caller's first name when we know one (never a phone number). */
export function callerFirstName(c: LiveCall): string | null {
  if (c.kind === 'unknown') return null;
  const name = (c.kind === 'renter' && c.renter ? c.renter.name : c.who).trim();
  if (!name || !/\p{L}/u.test(name) || name === c.display) return null;
  return name.split(/\s+/)[0] ?? null;
}
/** Which greeting fits the caller: a renter with a booking, a renter, a lead, an owner, a staff member, or unknown. */
export function greetingKey(c: LiveCall): string {
  if (!callerFirstName(c)) return 'unknown';
  if (c.kind === 'renter') return c.renter?.booking ? 'renter_booking' : 'renter';
  return c.kind;
}
const FALLBACK_GREETING = 'Thank you for calling CarmaCars, this is {staff}, how can I help?';
/** The greeting to read out, with the names filled in. A greeting that is off, or one whose words we cannot fill, falls
 *  back to the one for a caller we do not know. */
export function greetingFor(c: LiveCall, h: Pick<CallHelp, 'staff' | 'greetings'>): string {
  const words: Record<string, string | null | undefined> = { staff: h.staff, caller: callerFirstName(c), booking: c.renter?.booking?.number, car: c.renter?.booking?.car };
  const fill = (t: string) => t.replace(/\{(staff|caller|booking|car)\}/g, (all, k: string) => words[k] || all);
  const first = fill(h.greetings[greetingKey(c)] ?? '');
  if (first && !/\{[a-z_]+\}/.test(first)) return first;
  return fill(h.greetings.unknown ?? FALLBACK_GREETING).replace(/\{[a-z_]+\}/g, '').replace(/\s{2,}/g, ' ').trim();
}

// The pages a step may link to: the first part of the path under /admin and under /staff (model.test.ts checks each is a
// real folder of the app). A link written for one portal's page is sent to the other portal's page of the same job.
export const HELP_PAGES: Record<Portal, ReadonlySet<string>> = {
  admin: new Set(['offers', 'requests', 'bookings', 'renters', 'owners', 'leads', 'tasks', 'unanswered', 'messages', 'calendar', 'money', 'tolls', 'maintenance', 'visitors',
    'applications', 'hiring', 'damages', 'incidents', 'settings', 'vehicles', 'guide', 'sales-leads', 'deposit-reviews', 'referral-partners', 'owner-forms', 'owner-money', 'reviews']),
  va: new Set(['offers', 'requests', 'bookings', 'renters', 'owners', 'leads', 'tasks', 'unanswered', 'messages', 'calendar', 'money', 'tolls', 'maintenance', 'visitors',
    'quotes', 'card-coverage', 'today', 'cars', 'fleet', 'guide', 'sales-leads', 'deposit-reviews', 'referral-partners', 'owner-forms', 'owner-money', 'reviews', 'owner-leads', 'addons'])
};
const SAME_JOB: Record<Portal, Record<string, string>> = {
  admin: { '/quotes/new': '/offers/new', '/card-coverage': '/settings/card-coverage', '/owner-leads': '/owners?view=leads', '/cars': '/vehicles', '/today': '/tasks' },
  va: { '/vehicles': '/cars', '/settings/card-coverage': '/card-coverage' }
};
/** Where a helper link goes in this portal: its page, an https address as written, or null when this portal has no such
 *  page (the words are then shown without a link). */
export function helperHref(portal: Portal, target: string): string | null {
  if (/^https:\/\/[^\s]+$/.test(target)) return target;
  if (!/^\/[a-z0-9][a-z0-9/_?=&-]*$/.test(target)) return null;
  const path = SAME_JOB[portal][target] ?? target;
  const first = path.slice(1).split(/[/?]/)[0] ?? '';
  if (!HELP_PAGES[portal].has(first)) return null;
  return `${portal === 'admin' ? '/admin' : '/staff'}${path}`;
}
export type HelpPart = { text: string; href?: string; outside?: boolean };
/** A step or an answer as words and links: [Bookings](/bookings) becomes a link to the reader's own portal. */
export function helpParts(portal: Portal, text: string): HelpPart[] {
  const out: HelpPart[] = [];
  let last = 0;
  for (const m of text.matchAll(/\[([^\]\n]+)\]\(([^)\s]+)\)/g)) {
    if (m.index > last) out.push({ text: text.slice(last, m.index) });
    const href = helperHref(portal, m[2]!);
    out.push(href ? { text: m[1]!, href, ...(href.startsWith('https://') ? { outside: true } : {}) } : { text: m[1]! });
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push({ text: text.slice(last) });
  return out;
}
/** The quick answers that match what was typed: every word, in the question, the answer or the search words (any case);
 *  a match in the question first. Nothing typed: nothing. */
export function faqSearch(faq: HelpFaq[], q: string, max = 5): HelpFaq[] {
  const words = q.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 1);
  if (!words.length) return [];
  const plain = (s: string) => s.toLowerCase().replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
  return faq.map((f, i) => {
    const title = plain(f.q), all = `${title} ${plain(f.a)} ${f.keywords.toLowerCase()}`;
    return { f, i, hit: words.every((w) => all.includes(w)), inTitle: words.filter((w) => title.includes(w)).length };
  }).filter((x) => x.hit).sort((a, b) => b.inTitle - a.inTitle || a.i - b.i).slice(0, max).map((x) => x.f);
}
