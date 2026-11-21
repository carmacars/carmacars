// The live map's people layer (migration 3350, release 48 part MAP): what ops_read live_people returns and what the map
// draws from it. Staff on shift or on a job, renters and owners only around a pickup or return; the database already left
// out everyone this reader may not see (scope: all for Admin and Fleet, renters for customer service and Sales).
// No imports, so the unit tests run it as it is.

export type PersonRole = 'admin' | 'fleet' | 'cs' | 'sales' | 'finance' | 'field' | 'renter' | 'owner';
export type PersonReason = 'shift' | 'job' | 'pickup' | 'return';
export interface MapPerson {
  id: string; kind: 'staff' | 'renter' | 'owner'; role: PersonRole; name: string; lat: number; lng: number; accuracy_m?: number | null; at: string;
  reason: PersonReason; source: 'app' | 'web'; booking_number?: string | null; job?: { id: string; kind: string; status: string } | null;
}
export interface PeopleView { scope: 'all' | 'renters' | 'none'; people: MapPerson[] }

/** The role filters, in the legend's order. Colours from the map's dark palette (4.5:1 or more against #0b1020). */
export type PeopleFilter = 'staff' | 'field' | 'renter' | 'owner';
export const PEOPLE_FILTERS: Array<{ key: PeopleFilter; label: string; colour: string; roles: PersonRole[] }> = [
  { key: 'staff', label: 'Office staff', colour: '#c4b5fd', roles: ['admin', 'fleet', 'cs', 'sales', 'finance'] },
  { key: 'field', label: 'Field staff', colour: '#fde047', roles: ['field'] },
  { key: 'renter', label: 'Renters', colour: '#5eead4', roles: ['renter'] },
  { key: 'owner', label: 'Owners', colour: '#fdba74', roles: ['owner'] }
];
export const filterOf = (r: PersonRole): PeopleFilter => PEOPLE_FILTERS.find((f) => f.roles.includes(r))?.key ?? 'staff';
export const colourOfPerson = (p: Pick<MapPerson, 'role'>) => PEOPLE_FILTERS.find((f) => f.key === filterOf(p.role))!.colour;

const ROLE_WORD: Record<PersonRole, string> = { admin: 'Admin', fleet: 'Fleet', cs: 'Customer service', sales: 'Sales', finance: 'Finance', field: 'Field staff', renter: 'Renter', owner: 'Owner' };
const REASON_WORD: Record<PersonReason, string> = { shift: 'on shift', job: 'on a job', pickup: 'at a pickup', return: 'at a return' };
const JOB_WORD: Record<string, string> = { handover: 'hand-over', delivery: 'delivery', return_check_in: 'return check-in', pickup_from_renter: 'pickup from the renter' };

/** "MC" for Maya Chen, "A" for Ali, "?" for nothing. */
export function initials(name: string | null | undefined): string {
  const w = (name ?? '').trim().split(/\s+/).filter(Boolean);
  if (!w.length) return '?';
  return ((w[0]!.charAt(0) + (w.length > 1 ? w[w.length - 1]!.charAt(0) : '')).toUpperCase()) || '?';
}

/** The marker's label and the card's line: "Maya Chen, Fleet, on shift", "Rita Diaz, Renter, at a pickup (MP-1)". */
export function personLabel(p: Pick<MapPerson, 'name' | 'role' | 'reason' | 'booking_number' | 'job'>): string {
  const job = p.reason === 'job' && p.job ? ` (${JOB_WORD[p.job.kind] ?? p.job.kind.replace(/_/g, ' ')})` : '';
  const bk = p.booking_number && (p.reason === 'pickup' || p.reason === 'return') ? ` (${p.booking_number})` : '';
  return `${p.name}, ${ROLE_WORD[p.role] ?? p.role}, ${REASON_WORD[p.reason] ?? p.reason}${job}${bk}`;
}

/** The people the filters let through, with a real position. */
export function visiblePeople(v: PeopleView | null, hidden: ReadonlySet<PeopleFilter>): MapPerson[] {
  return (v?.people ?? []).filter((p) => Number.isFinite(p.lat) && Number.isFinite(p.lng) && Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180 && !hidden.has(filterOf(p.role)));
}

/** Counts per filter, for the chips. */
export function countPeople(v: PeopleView | null): Record<PeopleFilter, number> {
  const out = { staff: 0, field: 0, renter: 0, owner: 0 } as Record<PeopleFilter, number>;
  for (const p of v?.people ?? []) out[filterOf(p.role)]++;
  return out;
}

/** The filters this reader can ever see: everyone for Admin and Fleet, renters for customer service and Sales. */
export function filtersFor(scope: PeopleView['scope'] | undefined): typeof PEOPLE_FILTERS {
  return scope === 'all' ? PEOPLE_FILTERS : scope === 'renters' ? PEOPLE_FILTERS.filter((f) => f.key === 'renter') : [];
}

// ---------------------------------------------------------------- the own-location state (ops_read my_location)
export interface MyLocation {
  share: boolean; kind: 'staff' | 'renter' | 'owner' | null; role?: string; why: string; sharing_on?: boolean; locked?: boolean; reason?: PersonReason | null;
  on_shift?: boolean; booking_id?: string | null; field_job_id?: string | null;
  policy?: { version: string; text: string; accepted_at: string | null };
  latest?: { lat: number; lng: number; at: string } | null;
}

/** How often the page sends a position while it qualifies (the database stores at most one each 20 seconds). */
export const REPORT_MS = 60_000;
/** How often the page asks again whether it qualifies (a shift or a pickup window can start while it is open). */
export const STATE_MS = 5 * 60_000;

/** The settings card's line about now, in plain words. */
export function stateLine(s: MyLocation | null): string {
  if (!s) return 'Checking…';
  switch (s.why) {
    case 'policy': return 'Read and accept the electronic monitoring policy below. Until then nothing is shared.';
    case 'job': return 'Shared now: you are on a job. It stays on until the job is done.';
    case 'shift': return 'Shared now: you are on shift.';
    case 'off_duty': return 'Not shared: you are off duty. Nothing is taken until you clock in or start a job.';
    case 'off': return 'Off. Nothing is shared.';
    case 'pickup': return 'Shared now, around your pickup.';
    case 'return': return 'Shared now, around your return.';
    case 'no_booking': return 'Not shared now. It is shared only two hours either side of a pickup or return.';
    case 'view_as': return 'Not shared while viewing as another person.';
    default: return 'Not shared.';
  }
}

/** A position worth sending: a number in range, read in the last 2 minutes, accuracy under 5 km. */
export function goodFix(f: { lat: number; lng: number; accuracy?: number | null; at: number }, now = Date.now()): boolean {
  return Number.isFinite(f.lat) && Number.isFinite(f.lng) && Math.abs(f.lat) <= 90 && Math.abs(f.lng) <= 180 && now - f.at < 120_000 && now - f.at > -60_000
    && (f.accuracy === null || f.accuracy === undefined || f.accuracy < 5000);
}
