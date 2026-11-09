// The two-step deposit review of a returned booking and the Finance countdowns (release 35 part RR, migration 1010).
// Pure: the pages, the booking page and the unit tests share the words and the arithmetic.
import type { ReportPhoto } from '../handover/types.ts';

export type Item = 'fuel' | 'km' | 'damage' | 'late' | 'cleaning' | 'tickets' | 'tolls';
export interface Sign { result: 'ok' | 'issue'; amount_cents: number | null; note: string | null; by: string | null; at: string; photos?: number[] }
export interface ReviewItem { item: Item; label: string; facts: Record<string, unknown> & { suggest?: 'ok' | 'issue' }; fleet: Sign | null; finance: Sign | null; fleet_by_me: boolean | null }
export interface Place { key: string; name: string; url: string; check: { result: 'none_found' | 'ticket'; note: string | null; toll_ticket_id: string | null; by: string | null; at: string } | null }
export interface ReviewState {
  items: number; fleet_signed: number; finance_signed: number; issues: number; places: number; places_checked: number; tickets_found: number;
  fleet_done_at: string | null; finance_done_at: string | null; stage: 'fleet' | 'finance' | 'done';
}
export interface ReviewView {
  booking_id: string; booking_number: string; status: string; vehicle: string; plate: string | null; renter: string | null;
  pickup_at: string; return_at: string; checked_in_at: string | null; exists: boolean; state: ReviewState | null;
  items: ReviewItem[]; places: Place[]; toll_url: string; toll_window_ends_on: string | null;
  deposit: { status: string; method: string; amount_cents: number; held_back_cents: number; released_cents: number; applied_cents: number; release_due_on: string | null; hold_expires_at: string | null } | null;
  blockers: Array<{ kind: string; label: string }>;
  may: { fleet: boolean; finance: boolean; admin: boolean };
}
export interface ListRow { booking_number: string; plate: string | null; vehicle: string; renter: string | null; returned_at: string; state: ReviewState; in_window: boolean; deposit_status: string | null }
export interface SweepPlate { plate: string; vehicle: string; bookings: Array<{ booking_number: string; returned_at: string; new: boolean; in_window: boolean; stage: string }> }
export interface ReviewList {
  view: string; toll_url: string; places: Array<{ key: string; name: string; url: string }>; sweep_days: string;
  last_sweep: { run_on: string; since: string | null; cars: number } | null; sweep: SweepPlate[] | null; rows: ListRow[];
}

/** Where a review stands, in words. */
export function stageWords(s: ReviewState | null): string {
  if (!s) return 'No review';
  if (s.stage === 'done') return s.issues ? `Checked by Fleet and Finance: ${s.issues} ${s.issues === 1 ? 'issue' : 'issues'} to bill` : 'Checked by Fleet and Finance: nothing to bill';
  if (s.stage === 'finance') return `Finance to double-check: ${s.finance_signed} of ${s.items} items, ${s.places_checked} of ${s.places} ticket places`;
  return `Fleet to check: ${s.fleet_signed} of ${s.items} items`;
}

const DAYS: Record<string, string> = { mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday', fri: 'Friday', sat: 'Saturday', sun: 'Sunday' };
/** "mon,wed,fri" as "Monday, Wednesday and Friday". */
export function sweepDays(v: string): string {
  const names = v.split(',').map((x) => DAYS[x.trim()] ?? x.trim()).filter(Boolean);
  return names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}` : (names[0] ?? '');
}

/** The pickup and return photos paired angle by angle (the angle, else the shot); a photo with no partner keeps its row. */
export function pairPhotos<P extends Pick<ReportPhoto, 'seq' | 'shot' | 'angle' | 'damage_label'>>(pickup: P[], back: P[]): Array<{ key: string; out: P | null; in: P | null }> {
  const keyOf = (p: P) => (p.damage_label ? `damage:${p.damage_label}` : (p.angle || p.shot));
  const rows = new Map<string, { key: string; out: P | null; in: P | null }>();
  const add = (p: P, side: 'out' | 'in') => {
    let k = keyOf(p);
    // a second photo of the same angle on one side gets its own row
    for (let n = 2; rows.get(k)?.[side]; n++) k = `${keyOf(p)}#${n}`;
    const r = rows.get(k) ?? { key: k, out: null, in: null };
    r[side] = p; rows.set(k, r);
  };
  [...pickup].sort((a, b) => a.seq - b.seq).forEach((p) => add(p, 'out'));
  [...back].sort((a, b) => a.seq - b.seq).forEach((p) => add(p, 'in'));
  return [...rows.values()];
}

// ---------------------------------------------------------------- countdowns
export type Level = 'red' | 'amber' | 'ok' | null;
export interface Countdown {
  booking_id: string; booking_number: string; status: string; plate: string | null; vehicle: string; renter: string | null;
  hold_expires_at: string | null; reauth_at: string | null; hold_cents: number | null; reauth_running: boolean;
  return_due_at: string | null; return_due_on: string | null;
  pay_due_at: string | null; pay_state: 'overdue' | 'soon' | 'upcoming' | null; pay_cents: number | null; pay_plan: string | null;
  soonest_at: string; hold_level: Level; return_level: Level; pay_level: Level; level: Level;
}
export interface Countdowns { now: string; sort: 'soonest' | 'hold' | 'return' | 'payment'; rows: Countdown[] }

/** The level of a time: red within 24 hours or past, amber within 48. */
export function levelOf(at: string | null, now: number): Level {
  if (!at) return null;
  const ms = new Date(at).getTime() - now;
  return ms <= 24 * 3600_000 ? 'red' : ms <= 48 * 3600_000 ? 'amber' : 'ok';
}

/** Time left in words: "in 2 days 4 h", "in 5 h", "in 40 min", "3 h ago". */
export function timeLeft(at: string | null, now: number): string {
  if (!at) return '';
  const ms = new Date(at).getTime() - now;
  const a = Math.abs(ms);
  const d = Math.floor(a / 86_400_000), h = Math.floor((a % 86_400_000) / 3_600_000), m = Math.floor((a % 3_600_000) / 60_000);
  const txt = d > 0 ? `${d} ${d === 1 ? 'day' : 'days'}${h ? ` ${h} h` : ''}` : h > 0 ? `${h} h${m && h < 6 ? ` ${m} min` : ''}` : `${Math.max(m, 1)} min`;
  return ms >= 0 ? `in ${txt}` : `${txt} ago`;
}

export const PLAN: Record<string, string> = { weekly: 'Weekly', biweekly: 'Every 2 weeks', monthly: 'Monthly' };
export const SORTS: Array<[Countdowns['sort'], string]> = [['soonest', 'Soonest'], ['hold', 'Hold expiry'], ['return', 'Deposit return'], ['payment', 'Next payment']];
