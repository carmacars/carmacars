// The fleet calendar with many cars (r48 ops, docs/changes/2026-11-20-r48-ops-screens.md): filters by status, class,
// owner and availability, groups that fold, and the window of rows worth drawing when the list is long. No imports
// beyond the bar words: unit tested in Node.
import type { Avail } from './calendar-label.ts';

export interface FleetCar { id: string; label: string; plate: string | null; fleet_number: string | null; status: string; class: string | null; owner: string | null; supply_type?: string | null }
export type GroupBy = 'none' | 'class' | 'owner' | 'status' | 'avail';
export const GROUPS: Array<[GroupBy, string]> = [['none', 'No groups'], ['class', 'Class'], ['owner', 'Owner'], ['status', 'Car status'], ['avail', 'Availability']];
/** What "Availability" filters on: the badge of the car right now, or its free days in the dates shown. */
export type AvailFilter = '' | 'free_now' | 'free_today' | 'free_all' | 'out' | 'busy' | 'off';
export const AVAIL_FILTERS: Array<[AvailFilter, string]> = [['', 'Any availability'], ['free_now', 'Available now'], ['free_today', 'Free today'], ['free_all', 'Free every day shown'],
  ['out', 'Out or booked now'], ['busy', 'Blocked, in shop or on hold'], ['off', 'Not bookable']];
export interface FleetFilter { status: string; cls: string; owner: string; avail: AvailFilter }
export const NO_FILTER: FleetFilter = { status: '', cls: '', owner: '', avail: '' };

const words = (s: string) => { const t = s.replace(/_/g, ' '); return t.charAt(0).toUpperCase() + t.slice(1); };
export const statusWords = (s: string) => (s === 'out_of_service' ? 'In shop' : words(s));
const AVAIL_WORDS: Record<Avail['kind'], string> = { free: 'Available now', out: 'Out or booked now', busy: 'Blocked, in shop or on hold', off: 'Not bookable' };
const AVAIL_ORDER: Array<Avail['kind']> = ['free', 'out', 'busy', 'off'];

/** The values a filter offers, from the cars on the calendar: [value, words, how many cars], most cars first for owners. */
export function options(cars: FleetCar[], of: 'status' | 'class' | 'owner'): Array<[string, string, number]> {
  const n = new Map<string, number>();
  for (const c of cars) { const k = of === 'status' ? c.status : of === 'class' ? c.class ?? '' : c.owner ?? ''; if (k) n.set(k, (n.get(k) ?? 0) + 1); }
  const rows = [...n].map(([k, count]) => [k, of === 'owner' ? k : statusWords(k), count] as [string, string, number]);
  return rows.sort((a, b) => (of === 'owner' ? b[2] - a[2] : 0) || a[1].localeCompare(b[1]));
}

export function passes(c: FleetCar, a: Avail | undefined, f: FleetFilter): boolean {
  if (f.status && c.status !== f.status) return false;
  if (f.cls && (c.class ?? '') !== f.cls) return false;
  if (f.owner && (c.owner ?? '') !== f.owner) return false;
  if (!f.avail) return true;
  if (!a) return false;
  if (f.avail === 'free_now') return a.kind === 'free';
  if (f.avail === 'free_today') return a.freeToday;
  if (f.avail === 'free_all') return a.freeAll;
  return a.kind === f.avail;
}
export const filterCount = (f: FleetFilter) => [f.status, f.cls, f.owner, f.avail].filter(Boolean).length;

export interface Group<T> { key: string; label: string; cars: T[]; free: number }
/** The cars in groups (one group with an empty key when there is no grouping). The cars keep their order inside a group;
 * groups go by name, "none" last (availability: available first). */
export function groupCars<T extends FleetCar>(cars: T[], by: GroupBy, avail: (id: string) => Avail | undefined): Array<Group<T>> {
  const free = (list: T[]) => list.filter((c) => avail(c.id)?.freeToday).length;
  if (by === 'none') return [{ key: '', label: '', cars, free: free(cars) }];
  const at = new Map<string, T[]>();
  for (const c of cars) {
    const k = by === 'class' ? c.class ?? '' : by === 'owner' ? c.owner ?? '' : by === 'status' ? c.status : avail(c.id)?.kind ?? 'off';
    const list = at.get(k); if (list) list.push(c); else at.set(k, [c]);
  }
  const label = (k: string) => by === 'avail' ? AVAIL_WORDS[k as Avail['kind']] ?? words(k) : !k ? (by === 'class' ? 'No class' : by === 'owner' ? 'No owner on file' : 'No status')
    : by === 'owner' ? k : statusWords(k);
  const groups = [...at].map(([key, list]) => ({ key: key || '-', label: label(key), cars: list, free: free(list) }));
  if (by === 'avail') return groups.sort((a, b) => AVAIL_ORDER.indexOf(a.key as Avail['kind']) - AVAIL_ORDER.indexOf(b.key as Avail['kind']));
  return groups.sort((a, b) => Number(a.key === '-') - Number(b.key === '-') || a.label.localeCompare(b.label));
}

export type Row<T> = { kind: 'group'; key: string; label: string; count: number; free: number; open: boolean } | { kind: 'car'; key: string; car: T };
/** The rows to draw, top to bottom: a heading per group, then its cars unless it is folded. */
export function rowsOf<T extends FleetCar>(groups: Array<Group<T>>, folded: ReadonlySet<string>): Array<Row<T>> {
  const out: Array<Row<T>> = [];
  for (const g of groups) {
    const open = !folded.has(g.key);
    if (g.key) out.push({ kind: 'group', key: `g:${g.key}`, label: g.label, count: g.cars.length, free: g.free, open });
    if (open || !g.key) for (const c of g.cars) out.push({ kind: 'car', key: c.id, car: c });
  }
  return out;
}

/** Above this many rows only the rows near the screen are drawn (the rest are space of the same height). */
export const VIRTUAL_FROM = 40;
export const GROUP_H = 40;
/** Which rows to draw: those that touch the visible part of the list, plus `over` pixels each way. `tops` has one more
 * entry than there are rows (the total height last). */
export function windowOf(tops: number[], scrollTop: number, viewHeight: number, over = 600): { start: number; end: number; before: number; after: number } {
  const n = tops.length - 1;
  if (n <= 0) return { start: 0, end: 0, before: 0, after: 0 };
  const total = tops[n]!;
  const lo = Math.max(0, scrollTop - over), hi = Math.min(total, scrollTop + viewHeight + over);
  // the last row that starts at or before lo
  let a = 0, b = n - 1;
  while (a < b) { const m = (a + b + 1) >> 1; if (tops[m]! <= lo) a = m; else b = m - 1; }
  const start = a;
  let end = start;
  while (end < n && tops[end]! < hi) end++;
  return { start, end, before: tops[start]!, after: total - tops[end]! };
}
/** The top of each row from its height (one more entry than rows: the total). */
export function topsOf(heights: number[]): number[] {
  const t = new Array<number>(heights.length + 1); t[0] = 0;
  for (let i = 0; i < heights.length; i++) t[i + 1] = t[i]! + heights[i]!;
  return t;
}

// ---------------------------------------------------------------- the two jobs at the end of a trip
/** r48 ops: the jobs a car's row names: the return (a check-out, at its time) and the cleaning after the trip. */
export interface JobEntry { type: string; id: string; detail: string | null; starts_at: string; ends_at: string | null; status: string | null; reason: string | null; note: string | null;
  job?: string | null; done_at?: string | null; for_booking?: string | null; assignee?: string | null }
export type JobKind = 'checkout' | 'cleaning' | 'pickup' | 'other';
export const JOB_WORDS: Record<string, string> = { handover: 'Pickup check-in', delivery: 'Delivery', return_check_in: 'Return check-out', pickup_from_renter: 'Return check-out (we collect)',
  post_trip_cleaning: 'Post-trip cleaning', detail: 'Detail', photo_shoot: 'Photo shoot', tracker_install: 'Tracker install', tracker_removal: 'Tracker removal', registry_run: 'Registry run', recovery: 'Recovery', other: 'Job' };
/** The cleaning block a trip leaves behind (migration 0040) is the Post-trip cleaning job. */
export const isCleaningJob = (e: Pick<JobEntry, 'type' | 'reason' | 'note' | 'job'>) => e.job === 'post_trip_cleaning' || (e.type === 'block' && e.reason === 'cleaning' && (e.note ?? '').startsWith('Cleaning after booking'));
export const jobKind = (e: Pick<JobEntry, 'type' | 'detail' | 'reason' | 'note' | 'job'>): JobKind | null =>
  isCleaningJob(e) ? 'cleaning' : e.type === 'checkout' ? 'checkout' : e.type !== 'field_job' ? null : ['return_check_in', 'pickup_from_renter'].includes(e.detail ?? '') ? 'checkout' : ['handover', 'delivery'].includes(e.detail ?? '') ? 'pickup' : 'other';
const hm = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)).replace(/\./g, '').replace(/\s?a\s?m\b/i, ' am').replace(/\s?p\s?m\b/i, ' pm');
/** A job's words on the calendar: what it is and its time; a return that happened says when it actually came back. */
export function jobLabel(e: JobEntry): { kind: JobKind; name: string; time: string; done: boolean; full: string } {
  const kind = jobKind(e) ?? 'other';
  const name = kind === 'cleaning' ? JOB_WORDS.post_trip_cleaning! : JOB_WORDS[e.detail ?? 'other'] ?? words(e.detail ?? 'job');
  const done = kind === 'cleaning' ? !!e.done_at : e.status === 'done';
  const at = done && e.done_at ? e.done_at : e.starts_at;
  const time = kind === 'cleaning' && !done && e.ends_at ? `${hm(e.starts_at)} to ${hm(e.ends_at)}` : hm(at);
  const full = kind === 'checkout' ? `${name}: ${done ? 'returned' : 'due'} ${time}` : kind === 'cleaning' ? `${name}: ${done ? 'done' : ''} ${time}`.replace(/\s+/g, ' ') : `${name}: ${done ? 'done' : ''} ${time}`.replace(/\s+/g, ' ');
  return { kind, name, time, done, full };
}
/** The short words on the chip. */
export const chipWords = (l: ReturnType<typeof jobLabel>) => `${l.kind === 'checkout' ? 'Check-out' : l.kind === 'cleaning' ? 'Cleaning' : l.kind === 'pickup' ? 'Pickup' : l.name} ${l.time}`;

/** Where each job chip goes in the row's job lane so none sits on another: [row, left px, width px] by entry key. Chips
 * keep the width of their words (about 6.4px a character), not of their minutes. */
export function jobRows(entries: JobEntry[], leftOf: (iso: string) => number, max: number): { at: Map<string, { row: number; left: number; width: number }>; rows: number } {
  const at = new Map<string, { row: number; left: number; width: number }>();
  const ends: number[] = [];
  const list = entries.filter((e) => jobKind(e) !== null).map((e) => { const l = jobLabel(e); const width = Math.round(chipWords(l).length * 6.4 + 22); return { e, left: Math.min(Math.max(0, leftOf(e.starts_at)), Math.max(0, max - width)), width }; })
    .sort((a, b) => a.left - b.left);
  for (const j of list) {
    let r = ends.findIndex((x) => x + 4 <= j.left);
    if (r < 0) { r = ends.length; ends.push(j.left + j.width); } else ends[r] = j.left + j.width;
    at.set(`${j.e.type}${j.e.id}`, { row: r, left: j.left, width: j.width });
  }
  return { at, rows: ends.length };
}
export const JOB_H = 22;

/** What the calendar needs of an entry to name the end-of-trip jobs. */
export interface TripEntry extends JobEntry { booking_number: string | null; placeholder?: boolean; returned_at?: string | null; cleaned_at?: string | null }
const TRIP = ['confirmed', 'on_rent', 'returned', 'closed'];
/** The jobs of a car's row: its field jobs, the cleaning block each trip leaves, and for a trip with neither on file
 * (jobs made by hand, or a role that does not read field jobs) the return check-out and the cleaning from the booking
 * itself. A return that happened carries the time the car actually came back. */
export function jobsOf(entries: TripEntry[]): JobEntry[] {
  const trips = new Map(entries.filter((e) => e.type === 'booking' && e.booking_number).map((e) => [e.booking_number!, e]));
  const out: JobEntry[] = [];
  const hasOut = new Set<string>(), hasClean = new Set<string>();
  for (const e of entries) {
    const k = jobKind(e);
    if (!k) continue;
    const trip = e.for_booking ? trips.get(e.for_booking) : undefined;
    if (k === 'checkout') {
      if (e.for_booking) hasOut.add(e.for_booking);
      const back = trip?.returned_at ?? (e.status === 'done' ? e.done_at : null) ?? null;
      out.push({ ...e, status: back ? 'done' : e.status, done_at: back });
    } else if (k === 'cleaning') {
      if (e.for_booking) hasClean.add(e.for_booking);
      out.push({ ...e, job: 'post_trip_cleaning', done_at: e.done_at ?? trip?.cleaned_at ?? null });
    } else out.push(e);
  }
  for (const [n, t] of trips) {
    if (t.placeholder || !TRIP.includes(t.status ?? '') || !t.ends_at) continue;
    const at = t.returned_at ?? t.ends_at;
    if (!hasOut.has(n)) out.push({ for_booking: n, type: 'checkout', id: t.id, detail: 'return_check_in', starts_at: at, ends_at: null, status: t.returned_at ? 'done' : 'scheduled', reason: null, note: null, done_at: t.returned_at ?? null });
    if (!hasClean.has(n)) out.push({ for_booking: n, type: 'cleaning', id: t.id, detail: null, starts_at: at, ends_at: null, status: t.cleaned_at ? 'done' : 'scheduled', reason: 'cleaning', note: null, job: 'post_trip_cleaning', done_at: t.cleaned_at ?? null });
  }
  return out.sort((a, b) => a.starts_at.localeCompare(b.starts_at));
}
