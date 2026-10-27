// Offers without a request and rentals input fast (migration 0129): the choices and the payload the database takes.
// Pure, so the screens and the unit tests share it.
import { linesBeforeTax } from '../sales/taxIncluded.ts';

export type Role = 'admin' | 'cs' | 'sales';
export type PlaceKind = 'our_location' | 'delivery' | 'airport' | 'owner_location';
export type RentalPay = 'card' | 'e_transfer' | 'cash' | 'cheque' | 'bank_transfer' | 'platform_payout' | 'insurer';
export type DepositPay = 'card' | 'cash' | 'e_transfer' | 'none';

export const RENTAL_PAY: Array<[RentalPay, string, string]> = [
  ['card', 'Card, online', 'The renter approves, signs and pays by card on their phone. The usual way.'],
  ['e_transfer', 'e-Transfer', 'The renter signs online and sends an e-Transfer. You record it; the booking is confirmed then.'],
  ['cash', 'Cash', 'Paid in cash at the office or at pickup. You record it and confirm.'],
  ['cheque', 'Cheque', 'You record the cheque number when it comes in.'],
  ['bank_transfer', 'Bank transfer', 'You record the transfer reference when it arrives.'],
  ['platform_payout', 'Platform payout', 'Paid through Turo or another platform; nothing to collect from the renter.'],
  ['insurer', 'Insurer, billed later', 'An insurance replacement: the insurer is invoiced; the renter pays nothing at booking.']
];
export const DEPOSIT_PAY: Array<[DepositPay, string, string]> = [
  ['card', 'Card hold', 'A hold on the renter\'s card at pickup (or before, from the booking\'s Money tab).'],
  ['cash', 'Cash', 'Taken in cash; given back in cash with a receipt.'],
  ['e_transfer', 'e-Transfer', 'Sent by e-Transfer; given back by e-Transfer.'],
  ['none', 'No deposit', 'An Admin only: no deposit on this booking.']
];
export const PLACES: Array<[PlaceKind, string]> = [['our_location', 'Our location'], ['delivery', 'We deliver / collect'], ['airport', 'Airport'], ['owner_location', 'Owner\'s location']];
export const COVERAGE: Array<[string, string]> = [['1', 'Option 1: the renter\'s own insurance (OPCF 27)'], ['2', 'Option 2: credit card rental coverage'], ['3', 'Option 3: the Protection Plan']];

export interface OfferForm {
  renter_id: string | null;
  full_name: string; email: string; mobile: string; date_of_birth: string;
  vehicle_id: string; pickup_at: string; return_at: string;
  pickup_kind: PlaceKind; pickup_address: string; pickup_km: string;
  return_kind: PlaceKind; return_address: string; return_km: string;
  price_mode: 'sheet' | 'total' | 'day'; price_total: string; price_day: string; price_tax: 'plus' | 'included'; price_reason: string;
  deposit: string; discount: string; discount_reason: string; promo_code: string; km: string;
  coverage_option: string; plan_price: string;
  fees: Record<string, string>; fee_reason: string;
  rental_pay: RentalPay; deposit_pay: DepositPay;
  choice: '' | 'sourced' | 'for_carmacars';
  message: string; note: string; hours: string; by_email: boolean; by_text: boolean; notify: boolean;
}

export const cents = (s: string): number | null => {
  const t = String(s ?? '').replace(/[$,\s]/g, '');
  if (!t) return null;
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) : null;
};
const iso = (local: string): string | null => {
  if (!local) return null;
  const d = new Date(local);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
};
/** Rental days as the dates make them (24-hour periods, at least one); the database's count is shown once priced. */
export function daysBetween(from: string, to: string): number {
  const a = new Date(from).getTime(); const b = new Date(to).getTime();
  if (!Number.isFinite(a) || !Number.isFinite(b) || b <= a) return 0;
  return Math.max(1, Math.ceil((b - a) / 86_400_000));
}
const place = (kind: PlaceKind, address: string, km: string) => ({
  kind, address: address.trim() || null, distance_km: kind === 'delivery' && km.trim() ? Number(km) : null, airport_code: kind === 'airport' ? address.trim().toUpperCase() || null : null
});

/** The rental charge typed: the total, or a rate per day times the days. null: the rate sheet. */
export function typedRental(f: OfferForm, days: number): number | null {
  if (f.price_mode === 'total') return cents(f.price_total);
  if (f.price_mode === 'day') { const d = cents(f.price_day); return d === null || days <= 0 ? null : d * days; }
  return null;
}

/** What is missing before the offer can be priced (the database checks again and has the last word). */
export function missing(f: OfferForm, role: Role): string[] {
  const m: string[] = [];
  if (!f.renter_id) {
    if (!f.full_name.trim()) m.push('the customer\'s name');
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email.trim())) m.push('an email for the offer link');
    if (f.mobile.replace(/\D/g, '').length < 10) m.push('a mobile number');
    if (!f.date_of_birth) m.push('the date of birth');
  }
  if (!f.vehicle_id) m.push('the car');
  if (!f.pickup_at || !f.return_at) m.push('the dates');
  else if (daysBetween(f.pickup_at, f.return_at) === 0) m.push('a return after the pickup');
  if (f.price_mode !== 'sheet' && cents(f.price_mode === 'total' ? f.price_total : f.price_day) === null) m.push('the price');
  if (f.price_mode !== 'sheet' && !f.price_reason.trim()) m.push('the reason for the price');
  if (role !== 'admin' && !f.choice) m.push('who found this client');
  return m;
}

/** How the amounts were typed (2026-10-27): after tax, each line HST applies to is worked back to its amount before tax
 *  (bps: the settings' HST rate, from the priced offer; null before the first price) and the rental charge goes tax
 *  included; rentalWithTax: the rental charge worked out from the total the renter pays; extraResidual: the cents other
 *  lines typed after tax left (charges of their own), for the rental charge to take. */
export interface OfferTax { after: boolean; bps: number | null; hstFor: (key: string) => boolean; rentalWithTax?: number | null; extraResidual?: number }

/** The payload of app.staff_offer_create (and of its preview). Only what the person may change is sent: an assistant
 *  never sends the deposit or a discount, and fees only when Program settings let staff change fees (the database refuses
 *  them otherwise). */
export function offerPayload(f: OfferForm, role: Role, days: number, addons: Array<{ code: string; quantity: number; hours?: number | null }> = [], editFees: boolean = role === 'admin', tax?: OfferTax): Record<string, unknown> {
  const typed = typedRental(f, days);
  const after = tax ? tax.after : f.price_tax === 'included';
  // 0132: each fee line set by hand (its amount for the booking, before HST), by an Admin or by staff the settings allow
  const typedLines = editFees ? feeOverrides({ ...f.fees, ...(f.coverage_option === '3' && f.plan_price.trim() ? { coverage_sold: f.plan_price } : {}) }) : {};
  const conv = linesBeforeTax(Object.entries(typedLines).map(([key, c]) => ({ key, typed: c, hst: tax ? tax.hstFor(key) : true })), after && tax?.bps != null ? 'after' : 'before', tax?.bps ?? 0);
  const fromTotal = tax?.rentalWithTax ?? null;
  const rental = fromTotal !== null ? fromTotal : typed === null ? null : after ? Math.max(0, typed + conv.residual + (tax?.extraResidual ?? 0)) : typed;
  const changes: Record<string, unknown> = {};
  if (f.km) changes.km_allowance_per_day = Number(f.km);
  if (role === 'admin' && cents(f.discount)) { changes.staff_discount_cents = cents(f.discount); changes.staff_discount_reason = f.discount_reason.trim() || 'Discount given on the phone'; }
  const p: Record<string, unknown> = {
    ...(f.renter_id ? { renter_id: f.renter_id } : { renter: { full_name: f.full_name.trim(), email: f.email.trim(), mobile: f.mobile.trim(), date_of_birth: f.date_of_birth } }),
    vehicle_id: f.vehicle_id, pickup_at: iso(f.pickup_at), return_at: iso(f.return_at),
    pickup_location: place(f.pickup_kind, f.pickup_address, f.pickup_km), return_location: place(f.return_kind, f.return_address, f.return_km),
    coverage_option: Number(f.coverage_option), source: 'phone',
    rental_pay_method: f.rental_pay, deposit_pay_method: f.deposit_pay,
    message: f.message.trim() || null, note: f.note.trim() || null,
    expires_at: new Date(Date.now() + Math.max(1, Number(f.hours) || 24) * 3_600_000).toISOString(),
    notify: f.notify && (f.by_email || f.by_text), channels: { email: f.by_email, text: f.by_text }
  };
  if (f.choice) p.sales_choice = f.choice;
  if (rental !== null) { p.rental_charge_cents = rental; p.price_tax = fromTotal !== null || after ? 'included' : 'plus'; p.price_reason = f.price_reason.trim() || (fromTotal !== null ? 'Total agreed with the renter' : ''); }
  if (Object.keys(changes).length) p.changes = changes;
  if (role === 'admin' && cents(f.deposit) !== null) p.deposit_cents = cents(f.deposit);
  if (f.promo_code.trim()) p.promo_code = f.promo_code.trim().toUpperCase();
  if (Object.keys(conv.cents).length) { p.line_overrides = conv.cents; p.fee_reason = f.fee_reason.trim() || 'Agreed with the renter'; }
  if (addons.length) p.addons = addons;
  return p;
}

/** The before and after of an offer edited in place, in words (the history and the confirmation). */
export function describeRevision(before: { vehicle?: string; pickup_at?: string; return_at?: string; total_cents?: number; deposit_cents?: number },
  after: typeof before, fmtMoney: (c: number) => string, fmtWhen: (iso: string) => string): string[] {
  const out: string[] = [];
  if (before.vehicle !== after.vehicle) out.push(`Car: ${before.vehicle} to ${after.vehicle}`);
  if (before.pickup_at !== after.pickup_at && before.pickup_at && after.pickup_at) out.push(`Pickup: ${fmtWhen(before.pickup_at)} to ${fmtWhen(after.pickup_at)}`);
  if (before.return_at !== after.return_at && before.return_at && after.return_at) out.push(`Return: ${fmtWhen(before.return_at)} to ${fmtWhen(after.return_at)}`);
  if (before.total_cents !== after.total_cents && before.total_cents !== undefined && after.total_cents !== undefined) out.push(`Total: ${fmtMoney(before.total_cents)} to ${fmtMoney(after.total_cents)}`);
  if (before.deposit_cents !== after.deposit_cents && before.deposit_cents !== undefined && after.deposit_cents !== undefined) out.push(`Deposit: ${fmtMoney(before.deposit_cents)} to ${fmtMoney(after.deposit_cents)}`);
  return out;
}

/** The quick rental form's "paid by": the way of 0074 (mode) and the method of 0129. */
export type RentalPaidBy = 'card_on_file' | 'link' | 'e_transfer' | 'cash' | 'cheque' | 'bank_transfer' | 'platform_payout' | 'insurer' | 'unpaid';
export const RENTAL_PAID_BY: Array<[RentalPaidBy, string, string]> = [
  ['e_transfer', 'e-Transfer', 'Received: enter the reference.'],
  ['cash', 'Cash', 'Received in cash.'],
  ['card_on_file', 'Card on file', 'The saved card is charged when the renter signs.'],
  ['link', 'Payment link', 'The renter signs and pays online by card.'],
  ['platform_payout', 'Platform payout', 'Paid on Turo or another platform.'],
  ['insurer', 'Insurer, billed later', 'Insurance replacement: invoice the insurer.'],
  ['cheque', 'Cheque', 'Enter the cheque number.'],
  ['bank_transfer', 'Bank transfer', 'Enter the transfer reference.'],
  ['unpaid', 'Unpaid', 'Collect later.']
];
export function paymentOf(by: RentalPaidBy): { mode: 'other_way' | 'link' | 'card' | 'unpaid'; method?: string } {
  switch (by) {
    case 'card_on_file': return { mode: 'card' };
    case 'link': return { mode: 'link' };
    case 'unpaid': return { mode: 'unpaid' };
    case 'insurer': return { mode: 'unpaid', method: 'insurer' };
    default: return { mode: 'other_way', method: by };
  }
}
/** A reference is needed for these (the database says the same). */
export const needsReference = (by: RentalPaidBy | DepositPay) => by === 'e_transfer' || by === 'cheque' || by === 'bank_transfer';

// ---------------------------------------------------------------- 0132: fee lines set by hand, split payments, periods
/** The key of a price line, as the database keys a fee set by hand: an add-on by its code, anything else by its charge. */
export function lineKey(l: { charge_type: string; booking_addon_id?: string | null; detail?: { code?: string; addon_id?: string } | null }): string {
  const code = l.detail?.code;
  return code && (l.detail?.addon_id || l.booking_addon_id || l.charge_type === 'addon') ? `addon:${code}` : l.charge_type;
}
/** Lines that are the rental itself (their own fields), never edited as a fee. */
export const RENTAL_LINE = new Set(['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount']);
/** The fees typed (dollars) as the database takes them: {key: cents}; an empty box is left out (the computed amount). */
export function feeOverrides(typed: Record<string, string>): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(typed)) { const c = cents(v); if (c !== null && !RENTAL_LINE.has(k)) out[k] = c; }
  return out;
}
export interface PayPart { method: 'e_transfer' | 'cash' | 'cheque' | 'bank_transfer'; amount: string; reference: string }
export const PART_METHODS: Array<[PayPart['method'], string]> = [['cash', 'Cash'], ['e_transfer', 'e-Transfer'], ['cheque', 'Cheque'], ['bank_transfer', 'Bank transfer']];
/** What the payments typed add up to, and what is left to collect (never below zero). */
export function paidSoFar(first: number | null, parts: PayPart[], total: number): { paid: number; left: number } {
  const paid = (first ?? 0) + parts.reduce((s, p) => s + (cents(p.amount) ?? 0), 0);
  return { paid, left: Math.max(total - paid, 0) };
}
/** A period's share of a total, by its days (the last period takes what rounding leaves). */
export function periodShares(total: number, days: number[]): number[] {
  const all = days.reduce((s, d) => s + d, 0);
  if (!all) return days.map(() => 0);
  let used = 0;
  return days.map((d, i) => { if (i === days.length - 1) return total - used; const v = Math.round((total * d) / all); used += v; return v; });
}
