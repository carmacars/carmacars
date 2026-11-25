// Monthly check-in visits for long-term renters (release 50, migrations 4000 and 4001): the shapes the database returns
// and the words the renter's card, the renter's Pick a time page, the staff queue and the checklist share. Pure functions
// only (unit tested in model.test.ts).

export type VisitStatus = 'due' | 'booked' | 'done' | 'skipped' | 'cancelled';
export type Bucket = 'due' | 'booked' | 'overdue' | 'done';
export type Why = 'switched_on' | 'rolling' | 'rideshare' | 'long';
export interface NextService { label: string; status: string; km_left: number | null; due_on: string | null }
export interface Photo { angle: string; bucket: string; path: string }

export interface Visit {
  id: string; booking_id: string; vehicle_id: string; due_on: string; status: VisitStatus; bucket: Bucket;
  place: 'office' | 'request' | null; slot_at: string | null; request_note: string | null; place_words: string; time_words: string;
  reminded_at: string | null; followup_at: string | null; done_at: string | null; done_by_name?: string | null;
  odometer_km: number | null; damage_found: boolean | null; damage_note: string | null; tread_mm: number | null; fluids_ok: boolean | null;
  warning_lights: string | null; next_service: NextService | null; notes?: string | null; photos?: Photo[]; closed_reason: string | null;
  task_id?: string | null; damage_intake_id?: string | null;
  // the queue adds these
  booking_number?: string; renter_name?: string | null; renter_phone?: string | null; vehicle_name?: string; plate?: string | null;
}
export interface Slot { at: string; day: string }

export interface RenterState {
  on: boolean; booking_number?: string; why?: Why; next_on?: string | null; interval_days?: number; place_text?: string;
  visit?: Visit | null; slots?: Slot[]; last?: { done_on: string; odometer_km: number | null } | null;
}

export interface Queue {
  today: string; may_switch: boolean;
  settings: { enabled: boolean; interval_days: number; lead_days: number; min_days: number };
  visits: Visit[];
  upcoming: Array<{ booking_id: string; booking_number: string; next_on: string; vehicle_name: string; renter_name: string | null; why: Why }>;
}

export interface VisitRead {
  visit: Visit | null;
  booking: { id: string; booking_number: string; status: string; pickup_at: string; return_at: string };
  on: boolean; why: Why | null; next_on: string | null; switch: 'on' | 'off' | null; may_switch: boolean;
  car: { name: string; plate: string | null; current_km: number | null; tread_mm: number | null; next: NextService | null } | null;
  renter: { name: string | null; phone: string | null } | null;
  history: Visit[]; slots: Slot[];
}

export const BUCKETS: ReadonlyArray<readonly [Bucket, string]> = [['booked', 'Booked'], ['due', 'Due'], ['overdue', 'Overdue'], ['done', 'Done']];
export const BUCKET_TONE: Record<Bucket, string> = { booked: 'ad-b--light', due: 'ad-b--amber', overdue: 'ad-b--wait', done: 'ad-b--light' };
export const WHY_WORDS: Record<Why, string> = {
  switched_on: 'switched on by staff', rolling: 'a long-term rental paid weekly', rideshare: 'a rideshare or delivery driver', long: 'a long rental'
};

/** The five photos every visit takes: the four sides and the odometer. */
export const CHECKIN_ANGLES: ReadonlyArray<readonly [string, string]> = [['front', 'Front'], ['rear', 'Rear'], ['left', 'Left side'], ['right', 'Right side'], ['odometer', 'Odometer']];

/** The angles still missing a photo, in checklist order. */
export function missingAngles(photos: ReadonlyArray<Pick<Photo, 'angle'>>): string[] {
  const have = new Set(photos.map((p) => p.angle));
  return CHECKIN_ANGLES.filter(([k]) => !have.has(k)).map(([k]) => k);
}

const DAY = 86_400_000;
const noon = (d: string) => Date.parse(`${d}T12:00:00Z`);

/** "Monday, December 14" from YYYY-MM-DD (a calendar day, no zone shift). */
export function dayWords(d: string | null | undefined): string {
  if (!d) return '';
  return new Date(noon(d)).toLocaleDateString('en-CA', { weekday: 'long', month: 'long', day: 'numeric', timeZone: 'UTC' });
}

/** "2:30 pm" in Toronto time. */
export function timeWords(iso: string): string {
  return new Date(iso).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' }).replace(/\s?([ap])\.?m\.?/i, ' $1m').toLowerCase();
}

/** The renter's card title: "Next check-in visit: around Monday, December 14" (a booked time is named exactly). */
export function nextLine(s: RenterState): string | null {
  if (!s.on) return null;
  const v = s.visit;
  if (v?.status === 'booked') return v.slot_at ? `Your check-in visit: ${dayWords(torontoDay(v.slot_at))}, ${timeWords(v.slot_at)}` : 'Your check-in visit: by request, we will confirm the time';
  const on = v?.due_on ?? s.next_on;
  return on ? `Next check-in visit: around ${dayWords(on)}` : null;
}

/** The calendar day of an instant in Toronto (YYYY-MM-DD). */
export function torontoDay(iso: string): string {
  return new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });
}

/** The slots grouped by day, in order. */
export function slotsByDay(slots: readonly Slot[]): Array<[string, Slot[]]> {
  const m = new Map<string, Slot[]>();
  for (const s of [...slots].sort((a, b) => a.at.localeCompare(b.at))) m.set(s.day, [...(m.get(s.day) ?? []), s]);
  return [...m.entries()];
}

/** The queue's visits by bucket, each bucket in the database's order. */
export function byBucket(visits: readonly Visit[]): Record<Bucket, Visit[]> {
  const out: Record<Bucket, Visit[]> = { booked: [], due: [], overdue: [], done: [] };
  for (const v of visits) out[v.bucket].push(v);
  return out;
}

/** Days from today to a date: "in 3 days", "today", "2 days ago". */
export function dueIn(d: string, today: string): string {
  const n = Math.round((noon(d) - noon(today)) / DAY);
  if (n === 0) return 'today';
  if (n === 1) return 'tomorrow';
  if (n === -1) return 'yesterday';
  return n > 0 ? `in ${n} days` : `${-n} days ago`;
}

/** What the checklist found to look after, in words (the database raises the same To do). */
export function issuesOf(x: { tread_mm: number | null; fluids_ok: boolean | null; warning_lights: string | null; next?: NextService | null }): string[] {
  const out: string[] = [];
  if (x.next && (x.next.status === 'due_soon' || x.next.status === 'overdue')) out.push(`${x.next.label} ${x.next.status.replace('_', ' ')}`);
  if (x.tread_mm !== null && x.tread_mm < 3) out.push(`tire tread ${x.tread_mm} mm`);
  if (x.fluids_ok === false) out.push('fluids to top up or check');
  const l = (x.warning_lights ?? '').trim();
  if (l && !['none', 'no', 'n/a', '-'].includes(l.toLowerCase())) out.push(`warning light: ${l}`);
  return out;
}

/** The next service in words: "Oil and filter in 1,200 km" or "Brakes due Dec 3". */
export function serviceWords(n: NextService | null | undefined): string {
  if (!n) return 'No service schedule yet';
  if (n.km_left !== null) return n.km_left <= 0 ? `${n.label}: overdue by ${Math.abs(n.km_left).toLocaleString('en-CA')} km` : `${n.label} in ${n.km_left.toLocaleString('en-CA')} km`;
  return n.due_on ? `${n.label} due ${dayWords(n.due_on)}` : n.label;
}
