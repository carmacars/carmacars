// The insurance-replacement rate sheet (migration 0163): what a rate comes to under its caps (the same rule as
// app.insurer_rate_amount), whether a rate typed on a booking matches the insurer's sheet, how a sheet row reads, and the
// billing history as CSV. Pure functions: the Admin pages, Add a rental and the review screen share them.

export interface SheetRate {
  insurer_id?: string; insurer_name?: string; rate_id?: string; id?: string; class_code: string; class_label?: string; effective_from?: string;
  daily_rate_cents: number | null; weekly_cap_cents?: number | null; monthly_cap_cents?: number | null; delivery_allowance_cents?: number | null;
  km_per_day?: number | null; taxes_note?: string | null;
}

const money = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** What a daily rate comes to for `days` days: each full week at most the weekly cap (a part week no more than a week),
 *  each full 30 days at most the monthly cap (the rest no more than a month), never above rate x days. */
export function rateAmount(daily: number | null | undefined, weekly: number | null | undefined, monthly: number | null | undefined, days: number): number {
  if (daily == null || !(days > 0)) return 0;
  const weeks = (d: number) => (weekly == null ? daily * d : Math.floor(d / 7) * weekly + Math.min((d % 7) * daily, weekly));
  const capped = monthly == null ? weeks(days) : Math.floor(days / 30) * monthly + Math.min(weeks(days % 30), monthly);
  return Math.min(daily * days, capped);
}

/** One line for a sheet row: "$65.00 a day, at most $390.00 a week, delivery and pickup up to $50.00, 250 km a day". */
export function rateLine(r: Pick<SheetRate, 'daily_rate_cents' | 'weekly_cap_cents' | 'monthly_cap_cents' | 'delivery_allowance_cents' | 'km_per_day'>): string {
  if (r.daily_rate_cents == null) return 'No rate';
  return [`${money(r.daily_rate_cents)} a day`,
    r.weekly_cap_cents != null ? `at most ${money(r.weekly_cap_cents)} a week` : '',
    r.monthly_cap_cents != null ? `at most ${money(r.monthly_cap_cents)} for 30 days` : '',
    r.delivery_allowance_cents != null ? `delivery and pickup up to ${money(r.delivery_allowance_cents)}` : '',
    r.km_per_day != null ? (r.km_per_day === 0 ? 'unlimited km' : `${r.km_per_day} km a day`) : ''].filter(Boolean).join(', ');
}

export type RateCheck = { state: 'none' } | { state: 'sheet'; sheet: SheetRate } | { state: 'empty'; sheet: SheetRate } | { state: 'differs'; sheet: SheetRate; typed: number; message: string };

/** A rate typed against the insurer's sheet for the car: none (no sheet), sheet (the same), empty (the sheet's is taken)
 *  or differs (a reason is needed). */
export function rateCheck(typedCents: number | undefined | null, sheet: SheetRate | null | undefined, insurerName = 'the insurer'): RateCheck {
  if (!sheet || sheet.daily_rate_cents == null) return { state: 'none' };
  if (typedCents == null) return { state: 'empty', sheet };
  if (typedCents === sheet.daily_rate_cents) return { state: 'sheet', sheet };
  return { state: 'differs', sheet, typed: typedCents,
    message: `${money(typedCents)} a day differs from ${insurerName}'s rate sheet for ${sheet.class_label ?? sheet.class_code} (${money(sheet.daily_rate_cents)}): say why.` };
}

/** The rate a form shows after the insurer is chosen: the sheet's when the field is empty or still holds the rate the
 *  form filled in before (another insurer's); otherwise what staff typed. */
export function prefillRate(current: string, lastFilled: string | null, sheet: SheetRate | null | undefined): string {
  const filled = sheet?.daily_rate_cents != null ? (sheet.daily_rate_cents / 100).toFixed(2) : '';
  if (!current.trim() || (lastFilled !== null && current === lastFilled)) return filled;
  return current;
}

export interface BillingRow {
  booking_number: string; status: string; pickup_at: string; return_at: string; class_label: string | null; class_code: string; vehicle: string | null;
  renter: string | null; claim_number: string | null; bill_to: string; days_authorized: number | null; days_used: number | null; days_covered: number | null;
  daily_rate_cents: number | null; rate_source: string; sheet_rate_cents: number | null; rate_reason: string | null; share_cents: number | null;
  billed_cents: number; paid_cents: number; outstanding_cents: number; written_off_cents: number; days_to_pay: number | null;
  invoices: Array<{ invoice_number: string; status: string }>;
}

const SOURCE: Record<string, string> = { sheet: 'Rate sheet', override: 'Typed, with a reason', booking: 'Typed (no sheet)', none: 'No daily rate' };
export const rateSource = (s: string) => SOURCE[s] ?? s;

function cell(v: unknown): string {
  const t = v === null || v === undefined ? '' : String(v);
  return /[",\n\r]/.test(t) || /^[=+\-@]/.test(t) ? `"${(/^[=+\-@]/.test(t) ? `'${t}` : t).replace(/"/g, '""')}"` : t;
}
const dollars = (c: number | null | undefined) => (c == null ? '' : (c / 100).toFixed(2));

/** The billing history of one insurer as CSV: one line per booking, amounts in dollars, dates as Toronto days. */
export function billingCsv(insurer: string, rows: BillingRow[]): string {
  const day = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });
  const head = ['Insurer', 'Booking', 'Status', 'Class', 'Car', 'Renter', 'Claim', 'Pickup', 'Return', 'Bill to', 'Days authorized', 'Days used', 'Days covered',
    'Daily rate', 'Rate from', 'Sheet rate', 'Reason for a different rate', 'Insurer share', 'Billed', 'Paid', 'Outstanding', 'Written off', 'Days to pay', 'Invoices'];
  const lines = rows.map((r) => [insurer, r.booking_number, r.status, r.class_label ?? r.class_code, r.vehicle, r.renter, r.claim_number, day(r.pickup_at), day(r.return_at),
    r.bill_to === 'split' ? 'Rental only' : 'Rental and fees', r.days_authorized, r.days_used, r.days_covered, dollars(r.daily_rate_cents), rateSource(r.rate_source),
    dollars(r.sheet_rate_cents), r.rate_reason, dollars(r.share_cents), dollars(r.billed_cents), dollars(r.paid_cents), dollars(r.outstanding_cents), dollars(r.written_off_cents),
    r.days_to_pay, r.invoices.map((i) => `${i.invoice_number} (${i.status.replace(/_/g, ' ')})`).join('; ')].map(cell).join(','));
  return [head.map(cell).join(','), ...lines].join('\r\n') + '\r\n';
}

/** A file name for the export: carmacars-insurer-allstate-2026-10-25.csv */
export function billingFileName(insurer: string, today: string): string {
  const slug = insurer.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'insurer';
  return `carmacars-insurer-${slug}-${today}.csv`;
}
