// The field staff portal (release 35, part X; migrations 0930 and 0931): the shapes the database returns, the tabs, and the
// plain words of each card. Pure, unit-tested (model.test.ts).

import { torontoAt } from '../../lib/clock.ts';

export type CardType = 'job' | 'prep' | 'clean' | 'service' | 'photos';
export interface Addon { id: string; name: string; quantity: number; note: string | null; ticked: boolean; ticked_at: string | null; ticked_by: string | null }
export interface Blocker { code: string; label: string }
export interface Card {
  type: CardType; key: string; must: boolean; done: boolean;
  id?: string; kind?: string; leg?: 'pickup' | 'return' | null; status?: string; at?: string; place?: string | null; instructions?: string | null;
  vehicle: { id: string; name: string; plate: string | null };
  booking?: { id: string; number: string; status: string; renter: string | null; mobile: string | null } | null;
  addons?: Addon[]; addons_open?: number; clean?: { moment: string; done: boolean } | null; blockers?: Blocker[];
  items?: Array<{ code: string; label: string; done: boolean; at: string | null; note: string | null }>; note?: string | null;
  last?: string | null; days?: number | null; why?: string | null; update?: { status: string; note: string | null; at: string; by: string | null } | null; missing?: string[];
}
export interface Today {
  day: string; on_shift: boolean;
  shift: { id: string; starts_at: string; ends_at: string; note: string | null } | null;
  clock: { id: string; started_at: string } | null;
  cards: Card[];
  todo: Array<{ id: string; title: string; detail: string | null; type: string; related_id: string | null }>;
  counts: { must: number; done: number };
  /** r35 (1051): the jobs on the person's shift that day held by someone else on it (either may take one) */
  mates?: Mate[];
}
/** r40: Today as the page can always render it. A failed or partial read of field_read today gave an uncaught error in the
 *  page's server render, which reached the phone as React error 441 after every action (the actions revalidate /staff/field). */
export function safeToday(t: Partial<Today> | null | undefined, day: string): Today & { failed: boolean } {
  const ok = !!t && typeof t === 'object';
  const x = (ok ? t : {}) as Partial<Today>;
  return {
    day: typeof x.day === 'string' && x.day ? x.day : day, on_shift: !!x.on_shift, shift: x.shift ?? null, clock: x.clock ?? null,
    cards: Array.isArray(x.cards) ? x.cards.filter((c) => !!c && !!c.vehicle) : [], todo: Array.isArray(x.todo) ? x.todo : [],
    counts: { must: Number(x.counts?.must) || 0, done: Number(x.counts?.done) || 0 }, mates: Array.isArray(x.mates) ? x.mates : [], failed: !ok
  };
}
export interface Mate { id: string; kind: string; leg: 'pickup' | 'return' | null; at: string; status: string; place: string | null; vehicle: string; booking: string | null; who: string | null }
/** r35 (1051): the jobs of a shift by kind (the database's fx_slot_jobs). */
export interface ShiftJobs { pickups: number; returns: number; cleans: number; other: number; total: number }
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
/** "3 pickups, 1 return, 2 cleans": what waits on a shift; empty when nothing does. */
export function jobsText(j: ShiftJobs | null | undefined): string {
  if (!j || !j.total) return '';
  return [j.pickups ? plural(j.pickups, 'pickup', 'pickups') : '', j.returns ? plural(j.returns, 'return', 'returns') : '',
    j.cleans ? plural(j.cleans, 'clean', 'cleans') : '', j.other ? plural(j.other, 'other job', 'other jobs') : ''].filter(Boolean).join(', ');
}
export interface OpenMust { key: string; label: string }

/** The tabs of the field portal: at most four, and Sales for a person who opted in to sales. */
export interface Tab { href: string; label: string; icon: 'today' | 'shifts' | 'pay' | 'training' | 'sales' }
export function fieldTabs(opts: { salesOptIn?: boolean }): Tab[] {
  const t: Tab[] = [
    { href: '/staff/field', label: 'Today', icon: 'today' },
    { href: '/staff/field/shifts', label: 'My shifts', icon: 'shifts' },
    { href: '/staff/field/pay', label: 'My pay', icon: 'pay' },
    { href: '/staff/field/training', label: 'Training', icon: 'training' }
  ];
  if (opts.salesOptIn) t.push({ href: '/staff/field/sales', label: 'Sales', icon: 'sales' });
  return t;
}
/** The tab a path belongs to (a job card is Today's; the old addresses redirect). */
export function activeTab(path: string): Tab['icon'] {
  if (/^\/staff\/field\/shifts/.test(path)) return 'shifts';
  if (/^\/staff\/field\/(pay|hours)/.test(path)) return 'pay';
  if (/^\/staff\/field\/(training|guide)/.test(path)) return 'training';
  if (/^\/staff\/field\/(sales|rentals|referrals)/.test(path)) return 'sales';
  return 'today';
}

const JOB_WORDS: Record<string, string> = {
  handover: 'Pickup', delivery: 'Delivery to the renter', return_check_in: 'Return', pickup_from_renter: 'Collection from the renter', detail: 'Cleaning',
  photo_shoot: 'Listing photos', tracker_install: 'Tracker install', tracker_removal: 'Tracker removal', registry_run: 'Registry run', recovery: 'Recovery', other: 'Job'
};
/** The heading of a card in plain words. */
export function cardTitle(c: Pick<Card, 'type' | 'kind'>): string {
  if (c.type === 'job') return JOB_WORDS[c.kind ?? ''] ?? 'Job';
  return { prep: 'Onboarding prep', clean: 'Clean this car', service: 'Needs service', photos: 'Listing photos (spare time)' }[c.type as Exclude<CardType, 'job'>];
}

/** The one thing to do next on a card, for its single primary button. A pickup or return opens its job screen, where the clean
 *  check and the add-ons come first; once the job is done, a missing clean check is the card's last step. */
export function nextStep(c: Card): { label: string; what: 'open' | 'clean' | 'addons' | 'prep' | 'update' | 'photos' | 'done' } {
  if (c.done) return { label: 'Done', what: 'done' };
  if (c.type === 'clean') return { label: 'Check it clean', what: 'clean' };
  if (c.type === 'service') return { label: 'Give an update', what: 'update' };
  if (c.type === 'photos') return { label: 'Take the photos', what: 'photos' };
  if (c.type === 'prep') return { label: 'Open the prep', what: 'prep' };
  if (c.status === 'done' && c.clean && !c.clean.done) return { label: 'Check it clean', what: 'clean' };
  if (c.status === 'done' && (c.addons_open ?? 0) > 0) return { label: `Prepare the add-ons (${c.addons_open} to tick)`, what: 'addons' };
  return { label: c.leg === 'pickup' ? 'Start the pickup' : c.leg === 'return' ? 'Start the return' : 'Open the job', what: 'open' };
}

/** The steps of a car's card in order, each done or not (the card's small checklist). */
export function cardSteps(c: Card): Array<{ label: string; done: boolean }> {
  if (c.type === 'prep') return (c.items ?? []).map((i) => ({ label: i.label, done: i.done }));
  if (c.type !== 'job') return [];
  const s: Array<{ label: string; done: boolean }> = [];
  if (c.leg === 'pickup') {
    if (c.clean) s.push({ label: 'Clean check (tick and photo)', done: c.clean.done });
    if ((c.addons?.length ?? 0) > 0) s.push({ label: `Prepare the add-ons (${(c.addons ?? []).filter((a) => a.ticked).length} of ${c.addons!.length})`, done: (c.addons_open ?? 0) === 0 });
    s.push({ label: 'Pickup photos and handover', done: c.status === 'done' });
  } else if (c.leg === 'return') {
    s.push({ label: 'Return photos and check-in', done: c.status === 'done' });
    if (c.clean) s.push({ label: 'Clean check after the return', done: c.clean.done });
  } else s.push({ label: cardTitle(c), done: c.status === 'done' });
  return s;
}

/** A Canadian SIN: 9 digits that pass the Luhn check (the database never sees it in clear). */
export function sinDigits(v: string): string { return v.replace(/[\s-]/g, ''); }
export function validSin(v: string): boolean {
  const d = sinDigits(v);
  if (!/^\d{9}$/.test(d) || /^0+$/.test(d)) return false;
  let sum = 0;
  for (let i = 0; i < 9; i++) { let n = Number(d[i]); if (i % 2 === 1) { n *= 2; if (n > 9) n -= 9; } sum += n; }
  return sum % 10 === 0;
}
export const sinShown = (last3: string) => `***-***-${last3}`;

/** Dollars typed ("12.50", "$1,200") to cents; null when empty or not a number. */
export function toCents(s: string): number | null {
  const t = s.replace(/[$,\s]/g, '');
  if (!t) return null;
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  return Math.round(Number(t) * 100);
}

// r46: only Intl's numbers (lib/clock.ts), the words are ours. Intl's own "9:00 a.m." has a narrow no-break space on the
// server's ICU and a plain space in Chrome, so Admin > Field jobs (its work lists are drawn again in the browser) failed
// with React error 418 (the server's text did not match the browser's).
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** "9:05 AM" in Toronto. */
export const clockText = (iso: string) => { const p = torontoAt(iso); return p ? `${((p.hour + 11) % 12) + 1}:${String(p.minute).padStart(2, '0')} ${p.hour < 12 ? 'AM' : 'PM'}` : ''; };
/** "Sat, Nov 8" in Toronto. */
export const dayText = (iso: string) => { const p = torontoAt(iso); return p ? `${DAYS[p.weekday]}, ${MONTHS[p.month - 1]} ${p.day}` : ''; };
export const shiftText = (a: string, b: string) => `${dayText(a)}, ${clockText(a)} to ${clockText(b)}`;
/** Hours under 24 before the start: a give-up then is flagged as late. */
export const isLate = (startIso: string, now: number, hours = 24) => new Date(startIso).getTime() - now < hours * 3_600_000;

export const SPEND_KINDS: Array<[string, string]> = [['gas', 'Gas'], ['wash', 'Car wash or cleaning'], ['parts', 'Parts or supplies'], ['parking', 'Parking or transit'], ['other', 'Something else']];
export const PREP_ITEMS: Array<[string, string]> = [['safety_certificate', 'Safety certificate'], ['maintenance', 'Maintenance and repairs'], ['cleaning', 'Cleaning'],
  ['listing_photos', 'Listing photos'], ['plates_permit', 'Plates and permit pickup'], ['tracker', 'Install the tracker']];
export const CAR_UPDATES: Array<[string, string]> = [['taken_in', 'Taken in for service'], ['at_shop', 'Left at the shop'], ['waiting_parts', 'Waiting for parts'], ['sorted', 'Sorted, back on the road'], ['note', 'Just a note']];
