// Bookings > Now (migration 0330): the shape of app.fleet_board and the words and times the screen shows. Pure, so the
// unit tests and the server and client components share it. Every time is shown in Toronto time.

export interface CarPhoto { path: string; variants?: Array<{ width: number; path: string; format?: string }> | null; alt?: string | null }
export interface Car { id: string; name: string; code: string | null; plate: string | null; colour?: string | null; photo: CarPhoto | null }
export interface Renter { id: string; name: string; phone?: string | null; email?: string | null }
export type PayState = 'paid' | 'overdue' | 'soon' | 'upcoming' | 'none';
export type Plan = 'whole' | 'weekly' | 'biweekly' | 'monthly' | 'insurer' | 'owner';
export interface Instalment { seq: number; due_at: string; ends_at: string; cents: number; through_cents: number }
export interface Pay {
  plan: Plan; set: boolean; state: PayState; owed_cents: number; paid_cents: number; open_cents: number; count: number; per_cents: number | null; overdue_count: number;
  next: { seq: number; due_at: string; cents: number; instalment_cents: number } | null;
  insurer: { name: string | null; claim: string | null; share_cents: number; paid_cents: number } | null;
  schedule: Instalment[];
}
export interface Ready { licence: boolean; agreement: boolean; paid?: boolean; deposit: 'yes' | 'scheduled' | 'no'; photos: boolean }
export interface Rental {
  booking_id: string; number: string; status: string; type: string; car: Car; renter: Renter | null;
  pickup_at: string; booked_pickup_at: string; return_at: string; due: 'overdue' | 'today' | 'tomorrow' | 'later'; minutes_late: number | null; backdated: boolean;
  pickup_kind: string; return_kind: string; pickup_place: string | null; return_place: string | null;
  pay?: Pay; deposit?: { required_cents: number; waived: boolean; held_cents: number; how: string | null };
  km_out: number | null; fuel_out: number | null; unrecorded?: boolean; stale?: boolean; bill_to?: 'renter' | 'insurer' | 'split'; ready?: Ready;
}
export interface FreeCar extends Car { state: 'free' | 'maintenance'; why: string | null; note: string | null; until: string | null; idle_since: string | null; idle_days: number | null; next: { booking_id: string; number: string; pickup_at: string } | null }
export interface Summary { out: number; unrecorded?: number; stale?: number; due_today: number; overdue: number; going: number; money?: number; money_cents?: number; money_overdue?: number; free: number; maintenance: number; partner_cars?: number }
export interface Board { at: string; today: string; /** 0500: 'sales', the cars without the money or renters' contact */ scope: 'full' | 'field' | 'sales'; out: Rental[]; going: Rental[]; back: Rental[]; money?: Rental[]; stale?: Rental[]; cars: FreeCar[]; summary: Summary }

const TZ = 'America/Toronto';
const MIN = 60_000;

/** $1,234 (cents to whole dollars when even, else with cents). */
export function money(cents: number | null | undefined): string {
  const c = Number(cents ?? 0);
  const whole = c % 100 === 0;
  return new Intl.NumberFormat('en-CA', { style: 'currency', currency: 'CAD', currencyDisplay: 'narrowSymbol', minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: whole ? 0 : 2 }).format(c / 100);
}

/** "in 2d 4h", "in 3h 20m", "in 12m"; past: "3h 5m ago". Rounded down to the minute. */
export function span(ms: number): string {
  const m = Math.floor(Math.abs(ms) / MIN);
  const d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60), mm = m % 60;
  return d >= 2 ? `${d}d${h ? ` ${h}h` : ''}` : d === 1 ? `1d ${h}h` : h ? `${h}h ${String(mm).padStart(2, '0')}m` : `${mm}m`;
}

/** The countdown to a time from now: due in, or overdue by. */
export function countdown(iso: string, now: number): { text: string; late: boolean } {
  const ms = new Date(iso).getTime() - now;
  return ms >= 0 ? { text: `in ${span(ms)}`, late: false } : { text: `${span(ms)} late`, late: true };
}

const dayKey = (t: number) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(t));

/** Toronto: "Today 2:30 pm", "Tomorrow 10 am", "Yesterday 9 am", "Thu Nov 5, 10 am". */
export function when(iso: string, now: number): string {
  const t = new Date(iso).getTime();
  const time = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, hour: 'numeric', minute: '2-digit' }).format(t).replace(':00', '').replace(/\s?a\.m\./, ' am').replace(/\s?p\.m\./, ' pm');
  const k = dayKey(t), today = dayKey(now), tomorrow = dayKey(now + 86_400_000), yesterday = dayKey(now - 86_400_000);
  if (k === today) return `Today ${time}`;
  if (k === tomorrow) return `Tomorrow ${time}`;
  if (k === yesterday) return `Yesterday ${time}`;
  return `${new Intl.DateTimeFormat('en-CA', { timeZone: TZ, weekday: 'short', month: 'short', day: 'numeric' }).format(t).replace(/[.,]/g, '')}, ${time}`;
}

/** Toronto date only: "Thu Nov 5". */
export function day(iso: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(iso)).replace(/[.,]/g, '');
}

export const PLAN: Record<Plan, string> = { whole: 'Paid in full', weekly: 'Weekly', biweekly: 'Every 2 weeks', monthly: 'Monthly', insurer: 'Insurer billed', owner: 'Owner trip' };

/** The plan in a few words: "$700 a week", "$1,400 every 2 weeks", "$1,800 a month", "Insurer billed · Example Insurance". */
export function planWords(p: Pay | undefined): string {
  if (!p) return '';
  if (p.plan === 'insurer') return p.insurer?.name ? `Insurer billed · ${p.insurer.name}` : 'Insurer billed';
  if (p.plan === 'owner') return 'Owner trip';
  if (p.plan === 'whole') return p.owed_cents ? `Whole rental · ${money(p.owed_cents)}` : 'Nothing to pay';
  const per = p.per_cents ? money(p.per_cents) : '';
  const unit = p.plan === 'weekly' ? ' a week' : p.plan === 'biweekly' ? ' every 2 weeks' : ' a month';
  return per ? `${per}${unit}` : PLAN[p.plan];
}

/** The next payment in words and its tone: red when overdue, dark within 3 days, quiet otherwise. */
export function nextPay(p: Pay | undefined, now: number): { label: string; amount: string; tone: 'red' | 'dark' | 'ok' | 'quiet'; sub: string } {
  if (!p) return { label: '', amount: '', tone: 'quiet', sub: '' };
  if (p.state === 'none') return { label: p.plan === 'insurer' ? 'Insurer pays' : 'Nothing due', amount: '', tone: 'quiet', sub: p.insurer?.claim ? `Claim ${p.insurer.claim}` : '' };
  if (p.state === 'paid' || !p.next) return { label: 'Paid up', amount: money(p.paid_cents), tone: 'ok', sub: p.count > 1 ? `All ${p.count} paid` : '' };
  const of = p.count > 1 ? `${p.next.seq} of ${p.count}` : '';
  if (p.state === 'overdue') {
    const late = countdown(p.next.due_at, now).text.replace(' late', '');
    return { label: `Overdue ${late}`, amount: money(p.next.cents), tone: 'red', sub: p.overdue_count > 1 ? `${p.overdue_count} payments behind` : of ? `Payment ${of}` : '' };
  }
  return { label: when(p.next.due_at, now), amount: money(p.next.cents), tone: p.state === 'soon' ? 'dark' : 'quiet', sub: of ? `Payment ${of}` : '' };
}

/** tel: and sms: links for a Canadian or US number typed any way. */
export function phoneHref(phone: string | null | undefined, kind: 'tel' | 'sms'): string | null {
  const d = (phone ?? '').replace(/\D/g, '');
  if (d.length < 10) return null;
  const e164 = d.length === 10 ? `+1${d}` : d.length === 11 && d.startsWith('1') ? `+${d}` : `+${d}`;
  return `${kind}:${e164}`;
}

/** Fuel as eighths when the reading is a percentage: "6/8". */
export function fuel(pct: number | null | undefined): string {
  if (pct === null || pct === undefined) return '';
  return `${Math.round((pct / 100) * 8)}/8`;
}

export const km = (n: number | null | undefined) => (n === null || n === undefined ? '' : `${new Intl.NumberFormat('en-CA').format(n)} km`);

export const KIND: Record<string, string> = { delivery: 'Delivery', airport: 'Airport', owner_location: "Owner's place", our_location: 'Pickup' };

/** The deposit in words: "$1,000 held", "Waived", "None", "$500 cash". */
export function depositWords(d: Rental['deposit']): { text: string; ok: boolean } {
  if (!d) return { text: '', ok: true };
  if (d.waived) return { text: 'Waived', ok: true };
  if (d.held_cents > 0) return { text: `${money(d.held_cents)} ${d.how === 'cash' ? 'cash' : d.how === 'e_transfer' ? 'e-Transfer' : d.how === 'charged' ? 'charged' : 'held'}`, ok: true };
  if (!d.required_cents) return { text: 'None', ok: true };
  return { text: `${money(d.required_cents)} not held`, ok: false };
}

export type OutFilter = 'all' | 'late' | 'today' | 'pay';
export function filterOut(rows: Rental[], f: OutFilter): Rental[] {
  if (f === 'late') return rows.filter((r) => r.due === 'overdue');
  if (f === 'today') return rows.filter((r) => r.due === 'today' || r.due === 'overdue');
  if (f === 'pay') return rows.filter((r) => r.pay && ['overdue', 'soon'].includes(r.pay.state));
  return rows;
}

/** The initial for a car with no photo: "Mercedes-Benz C 300" is M. */
export const initial = (name: string) => (name.replace(/^\d{4}\s+/, '').trim()[0] ?? '?').toUpperCase();

/** The photo address at a width (the variants of 0149), or the original. */
export function photoPath(p: CarPhoto | null | undefined, w: number): string | null {
  if (!p?.path) return null;
  const v = (p.variants ?? []).filter((x) => x?.path && x.width >= w).sort((a, b) => a.width - b.width)[0];
  return v?.path ?? p.path;
}

export type BillFilter = 'all' | 'renter' | 'insurer';
/** Bill to: the renter, or an insurer (billed in full or split with the renter). */
export const billed = (r: Rental, f: BillFilter) => f === 'all' || (f === 'renter' ? (r.bill_to ?? 'renter') === 'renter' : (r.bill_to ?? 'renter') !== 'renter');
export const BILL_WORDS: Record<string, string> = { renter: 'Renter', insurer: 'Insurer', split: 'Insurer and renter' };
