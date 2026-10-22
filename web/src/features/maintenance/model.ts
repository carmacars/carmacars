// The maintenance tracker's shapes and words (migration 0089), shared by the fleet overview, the car's Maintenance tab,
// the record pop-up and the owner's service history. Pure functions only (unit tested in model.test.ts).

export type Status = 'overdue' | 'due_soon' | 'unknown' | 'ok' | 'none' | 'off';
export type Season = 'summer' | 'all_season' | 'winter' | 'all_weather';
export type Payer = 'company' | 'owner' | 'claim' | 'renter' | 'none';
export type Billing = 'billed' | 'not_billed' | 'needs_admin' | 'no_charge';

export interface Chip { code: string; label: string; status: Status }
export interface Next { code: string; label: string; status: Status; detail: string | null; due_on: string | null }
export interface CarRow {
  vehicle_id: string; name: string; plate: string | null; fleet_number: string | null; vehicle_status: string; class: string | null; supply_type: string;
  owner_name: string | null; current_km: number | null; km_per_day: number | null; worst: Status; rank: number; overdue: number; due_soon: number; unknown: number;
  due_on: string | null; next: Next | null; tires: { season: Season; tread_mm: number | null } | null; chips: Chip[] | null; last_service_on: string | null;
}
export interface Overview { today: string; can_settings: boolean; items: Array<{ code: string; label: string }>; to_bill: number; cars: CarRow[] }

export interface Item {
  code: string; label: string; kind: 'interval' | 'record' | 'expiry' | 'tires' | 'seasonal'; interval_km: number | null; interval_months: number | null;
  soon_km: number | null; soon_days: number | null; block_bookings: boolean; block_handover: boolean; active: boolean; rule_source: 'car' | 'class' | 'default';
  last_done_on: string | null; last_done_km: number | null; expires_on: string | null; expires_source: string | null; next_due_on: string | null; next_due_km: number | null;
  projected_due_on: string | null; due_on: string | null; status: Status; detail: string | null;
}
export interface TireSet {
  id: string; season: Season; size: string | null; brand: string | null; model: string | null; tread_mm: number | null; tread_measured_on: string | null;
  made_on: string | null; purchased_on: string | null; storage_location: string | null; on_car: boolean; retired_on: string | null; retired_reason: string | null; notes: string | null;
}
export interface ServiceRecord {
  id: string; done_on: string; odometer_km: number | null; odometer_estimated: boolean; shop: string | null; notes: string | null; cost_cents: number; hst_cents: number;
  payer: Payer; billing_status: Billing; source: 'manual' | 'expense'; items: Array<{ code: string; label: string; expires_on: string | null; tread_mm: number | null }>;
  company_expense_id: string | null; owner_deduction: { id: string; status: string } | null; claim_number: string | null; booking_number: string | null;
  receipt_document_id: string | null; created_by_name: string | null; created_at: string; voided_at: string | null; void_reason: string | null;
}
export interface Reading { id: string; read_at: string; km: number; source: string; voided_at: string | null }
export interface CarMaintenance {
  vehicle_id: string; name: string; plate: string | null; class: string | null; fuel: string | null; supply_type: string; tracked: boolean; today: string;
  current_km: number | null; km_per_day: { rate: number; source: 'readings' | 'rentals' | 'default'; days: number | null };
  items: Item[]; handover_block: string | null; tire_sets: TireSet[]; swaps: Array<{ swapped_on: string; odometer_km: number | null; from: string | null; to: string | null }>;
  records: ServiceRecord[]; readings: Reading[]; payers: Array<[Payer, string]>; default_payer: Payer;
  claims: Array<{ id: string; claim_number: string; status: string }>; bookings: Array<{ id: string; booking_number: string; pickup_at: string; return_at: string }>;
  rules: Array<Record<string, unknown>>; can_settings: boolean; is_admin: boolean; limit_cents: number | null; hst_bps: number;
}
export interface OwnerHistory {
  items: Array<{ label: string; status: Status; detail: string | null; last_done_on: string | null }>;
  tires: { season: string; tread_mm: number | null } | null;
  records: Array<{ done_on: string; odometer_km: number | null; shop: string | null; items: string | null; billed_to_you_cents: number | null; paid_by: string }>;
}

export const STATUS_LABEL: Record<Status, string> = { overdue: 'Overdue', due_soon: 'Due soon', unknown: 'Unknown', ok: 'OK', none: 'No schedule', off: 'Off' };
/** The admin badge tone of a status (admin.css: .ad-b--red, --amber, --wait, --light). */
export const STATUS_TONE: Record<Status, string> = { overdue: 'ad-b--red', due_soon: 'ad-b--amber', unknown: 'ad-b--wait', ok: 'ad-b--light', none: 'ad-b--light', off: 'ad-b--light' };
export const SEASON_LABEL: Record<Season, string> = { summer: 'Summer', all_season: 'All-season', winter: 'Winter', all_weather: 'All-weather' };
export const SEASONS: Array<[Season, string]> = (Object.keys(SEASON_LABEL) as Season[]).map((s) => [s, SEASON_LABEL[s]]);
export const BILLING_LABEL: Record<Billing, string> = { billed: 'Billed', not_billed: 'Not billed yet', needs_admin: 'Waiting for an Admin to bill', no_charge: 'No charge' };
export const READING_SOURCE: Record<string, string> = {
  handover: 'Handover report', return: 'Return report', condition_report: 'Condition report', move: 'Field staff move', rental: 'Rental odometer',
  listing: 'Listing photos', car: 'Car record', service: 'Service', manual: 'Entered by hand'
};
export const KMD_SOURCE: Record<string, string> = { readings: 'from the odometer readings', rentals: 'from the rentals', default: 'assumed (Program settings) until readings come in' };

export const rank = (s: Status): number => ({ overdue: 0, due_soon: 1, unknown: 2, ok: 3, none: 4, off: 5 })[s] ?? 5;

export const kmText = (n: number | null | undefined): string => (n === null || n === undefined ? '' : `${Math.round(n).toLocaleString('en-CA')} km`);

/** "Overdue", "Due soon"... with the item: "Oil and filter overdue". */
export function chipText(c: { label: string; status: Status }): string {
  return c.status === 'ok' ? c.label : `${c.label}: ${STATUS_LABEL[c.status].toLowerCase()}`;
}

export type Show = '' | 'due' | 'overdue' | 'due_soon' | 'unknown' | 'ok' | 'bill';
export const SHOWS: Array<[Show, string]> = [['', 'All cars'], ['due', 'Overdue or due soon'], ['overdue', 'Overdue'], ['due_soon', 'Due soon'], ['unknown', 'No record yet'], ['ok', 'All OK']];

/** The overview's filters: what to show, one item, a search on name, plate or fleet number. Most urgent first, then the
 *  earliest due date, then the name (the database's order, kept for a re-sort by the client). */
export function filterCars(cars: CarRow[], f: { show?: string; item?: string; q?: string; sort?: string }): CarRow[] {
  const q = (f.q ?? '').trim().toLowerCase();
  const out = cars.filter((c) => {
    const chips = c.chips ?? [];
    if (f.item) {
      const it = chips.find((x) => x.code === f.item);
      if (!it) return false;
      if (f.show === 'due' && !['overdue', 'due_soon'].includes(it.status)) return false;
      if (f.show && !['due', 'bill', ''].includes(f.show) && it.status !== f.show) return false;
    } else {
      if (f.show === 'due' && !(c.overdue > 0 || c.due_soon > 0)) return false;
      if (f.show === 'overdue' && !(c.overdue > 0)) return false;
      if (f.show === 'due_soon' && !(c.due_soon > 0 && c.overdue === 0)) return false;
      if (f.show === 'unknown' && !(c.unknown > 0)) return false;
      if (f.show === 'ok' && c.worst !== 'ok') return false;
    }
    if (q && ![c.name, c.plate ?? '', c.fleet_number ?? '', c.owner_name ?? ''].some((s) => s.toLowerCase().includes(q))) return false;
    return true;
  });
  const byDue = (a: CarRow, b: CarRow) => (a.due_on ?? '9999').localeCompare(b.due_on ?? '9999');
  if (f.sort === 'name') return out.sort((a, b) => a.name.localeCompare(b.name));
  if (f.sort === 'km') return out.sort((a, b) => (b.current_km ?? 0) - (a.current_km ?? 0));
  if (f.sort === 'due') return out.sort((a, b) => byDue(a, b) || a.name.localeCompare(b.name));
  return out.sort((a, b) => a.rank - b.rank || byDue(a, b) || a.name.localeCompare(b.name));
}

/** HST on a cost, at the rate in Program settings (basis points), rounded to the cent. */
export const hstOf = (costCents: number, bps = 1300): number => Math.round((costCents * bps) / 10000);

/** The items a pop-up opens with: the ones due (from a To do prompt) or none. */
export function preselect(items: Array<Pick<Item, 'code' | 'status'>>, only?: string[]): string[] {
  if (only?.length) return items.filter((i) => only.includes(i.code)).map((i) => i.code);
  return items.filter((i) => i.status === 'overdue' || i.status === 'due_soon').map((i) => i.code);
}

/** What happens to the bill, in words, for the pop-up's summary line. */
export function billingWords(payer: Payer, billed: boolean, totalCents: number, limitCents: number | null, supply: string): string {
  if (payer === 'none' || totalCents === 0) return 'No bill: the service is recorded and the timers reset.';
  if (payer === 'owner' && supply === 'partner') return 'The partner pays the shop directly: nothing is billed here.';
  if (!billed) return 'Recorded now, billed later: press Bill now on the record when the bill comes in.';
  if (limitCents !== null && totalCents > limitCents) return 'Above your single limit: the service is recorded and an Admin bills it.';
  return {
    company: 'Entered as a company expense under the matching service category.',
    owner: 'Deducted from the owner\'s next statement as an owner cost (owner agreement 11.1).',
    claim: 'Added to the claim as a repair cost.',
    renter: 'Charged to the renter at cost on the booking, as a post-rental charge.',
    none: ''
  }[payer];
}

/** "Dec 1" style due words from an ISO date and today (both YYYY-MM-DD). */
export function dueWords(due: string | null, today: string): string {
  if (!due) return '';
  const days = Math.round((Date.parse(`${due}T12:00:00Z`) - Date.parse(`${today}T12:00:00Z`)) / 86_400_000);
  if (days === 0) return 'today';
  if (days === 1) return 'tomorrow';
  if (days === -1) return 'yesterday';
  return days > 0 ? `in ${days} days` : `${-days} days ago`;
}
