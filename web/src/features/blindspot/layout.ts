// The Blind Spot Car Rental agreement (CarmaCars rents under Blind Spot's insurance): the second rental agreement of a
// booking, beside CarmaCars' own (docs/changes/2026-10-23-second-rental-agreement.md). The template is Blind Spot's own
// two-page form (Admin > Settings > Forms); it has no fillable field, so each value is drawn in its box at the place
// measured on the form (A4, 595.28 x 841.89 points). Coordinates here are from the top of the page, in points.
// This file maps a booking to what goes in each box; fill.ts draws it. Never invents: a box with no value stays blank.
// Relative imports with their extension: the unit tests run this file in Node directly.
// 0154: the pickup copy fills the time out, K/M out and fuel out from the check-out; the closing copy fills boxes 25 to
// 31 (time and date in, K/M in, driven, allowed, charged), the hours late, the extra days, damages, fuel, the other
// return charges, the deposit received, the balance and what was paid; a car swapped during the rental fills the
// replacement vehicle column; the insurance replacement fills the insured vehicle and box 13 (OPCF 27: the renter's own
// insurer and policy in boxes 12 and 13); box 48 carries the charges with no box of their own, so the subtotal adds up.
import type { AgreementExtra, AgreementVehicle } from '../agreement/extra.ts';

export const PAGE_H = 841.89;
export const PINK = { r: 255 / 255, g: 186 / 255, b: 204 / 255 };
export const WHITE = { r: 1, g: 1, b: 1 };
/** the deposit received box's darker pink, and the blue of the form's rules */
export const ROSE = { r: 224 / 255, g: 164 / 255, b: 180 / 255 };
export const RULE = { r: 75 / 255, g: 128 / 255, b: 158 / 255 };

/** The facts of a booking for the form: the rental agreement's own (public.server_agreement_facts) and the extra ones
 *  of public.server_blindspot_facts (the mailing address, the HST number, the insurer, the odometer, the template). */
export interface BlindSpotFacts {
  booking: {
    booking_number: string; agreement_number: string | null; pickup_at: string; return_at: string; billable_days: number;
    rate_applied: string | null; daily_rate_cents: number | null; weekend_rate_cents: number | null; weekly_rate_cents: number | null;
    monthly_rate_cents: number | null; multi_day_rate_cents?: number | null; rental_charge_cents: number; km_allowance_per_day: number | null;
    km_allowance_total: number | null; overage_cents_per_km: number | null; deposit_cents: number; subtotal_at_booking_cents: number;
    hst_at_booking_cents: number; total_due_at_booking_cents: number; coverage_option?: number | null;
    /** the daily rate's days and the weekend rate's days of a 1 to 6 day rental (the agreement facts carry them) */
    daily_days?: number | null; weekend_days?: number | null;
  };
  renter: { legal_name: string | null; date_of_birth: string | null; mobile: string | null; address_line1: string | null; address_line2: string | null;
    city: string | null; province: string | null; postal_code: string | null } | null;
  drivers: Array<{ role: string; full_name: string; date_of_birth: string | null; licence_number: string | null; licence_issuer: string | null; licence_expiry: string | null }>;
  vehicle: { year: number; make: string; model: string; trim: string | null; plate: string | null } | null;
  lines: Array<{ charge_type: string; description: string; amount_cents: number }>;
  card: { brand: string; last4: string } | null;
  extra: {
    mailing: { line: string | null; street: string | null; unit: string | null; city: string | null; province: string | null; postal_code: string | null };
    hst_number: string | null;
    fleet_number: string | null;
    odometer_out_km: number | null;
    insurer: { name: string | null; claim_number: string | null; adjuster_name: string | null; adjuster_phone: string | null; authorized_days: number | null; authorized_daily_rate_cents: number | null } | null;
    /** 0154: the facts beyond the booking's own (pickup and return records, swaps, payments, every line...) */
    more?: AgreementExtra | null;
    /** 0154: the coverage proof (OPCF 27 insurer and policy, the card of card coverage) */
    coverage?: { coverage_option: number; insurer_name: string | null; policy_number: string | null; policy_expiry: string | null; card_issuer: string | null; card_last4: string | null;
      coverage_provider?: string | null; activation_ref?: string | null } | null;
    /** 0154: the card on file's expiry */
    card_expiry?: string | null;
  };
}

export type Align = 'left' | 'right' | 'center';
/** A value in a box: x is the left edge (the right edge when right-aligned, the centre when centred), y the baseline. */
export interface Text { box: string; text: string; x: number; y: number; w: number; size: number; align?: Align; bold?: boolean }
export interface Cover { box: string; x: number; y: number; w: number; h: number; color: 'white' | 'pink' | 'rose' | 'rule' }
export interface Dot { box: string; x: number; y: number; r: number }
/** Where a signature goes: the rectangle it is fitted in (top, from the top of the page). */
export interface SigBox { box: string; x: number; top: number; w: number; h: number }

// ---------------------------------------------------------------- the boxes, measured on Blind Spot's form
// What is printed on the blank form and replaced (the owner's request of October 23, 2026): the old address at the top
// left and twice in box 15, Blind Spot's HST number of box 1, and the "Sam" signature of box 21; and box 40's "T B D".
export const COVERS: Cover[] = [
  { box: 'address', x: 45, y: 79, w: 258, h: 20, color: 'white' },
  { box: 'hst', x: 61, y: 106.5, w: 162, h: 17.5, color: 'white' },
  { box: '15-from', x: 20, y: 522.6, w: 92.8, h: 8.6, color: 'pink' },
  { box: '15-to', x: 205.8, y: 522.6, w: 82, h: 8.6, color: 'pink' },
  { box: '21', x: 137, y: 799, w: 57, h: 26, color: 'pink' },
  // 40: the printed "T B D" under M, DD and YYYY, where the due-back date goes
  { box: '40', x: 291, y: 440.8, w: 87.5, h: 8.8, color: 'pink' },
  // the fuel gauges: the printed circles of FUEL OUT (pink row) and FUEL IN (white row) touch and read as "8 8 8 8 8";
  // covered, and the level of the check-out (and check-in) report written in words instead (blank with no reading)
  // (the FUEL IN circles run over the rule under their row: covered too, the rule drawn again)
  { box: 'fuel-out', x: 320.5, y: 674.5, w: 135.8, h: 8.6, color: 'pink' },
  { box: 'fuel-in', x: 320.5, y: 683.0, w: 135.8, h: 12.0, color: 'white' },
  { box: 'fuel-in-59', x: 339.5, y: 695.0, w: 93, h: 0.5, color: 'rose' },
  { box: 'fuel-in-rule', x: 320.5, y: 693.7, w: 135.8, h: 1.1, color: 'rule' }
];
/** The line under box 21's signature, drawn again where the old signature crossed it. */
export const LINE_21 = { x1: 137, x2: 194, y: 823.7, thickness: 0.32 };
/** The pre-printed annotations of the blank form that carry the old address (removed; the new one is drawn instead). */
export const OLD_ADDRESS = /crockford/i;

export const SIG = {
  /** 16, Loss Damage Waiver: the renter's signature (the LDW is not purchased: "Full Value") */
  ldw: { box: '16', x: 160, top: 567, w: 100, h: 19 } as SigBox,
  /** 17, parking tickets, traffic violations and toll road charges */
  tickets: { box: '17', x: 209, top: 610, w: 76, h: 13 } as SigBox,
  /** 19 and 20: "I have read the terms and conditions of page 1 and page 2", the renter's signature */
  terms: { box: '20', x: 75, top: 762, w: 155, h: 21.5 } as SigBox,
  /** 21: the signature of the authorized company representative */
  company: { box: '21', x: 118, top: 799, w: 165, h: 25 } as SigBox,
  /** 10: additional renters' signatures (each driver signs on their own link) */
  drivers: { box: '10', x: 200, top: 314.5, w: 118, h: 13 } as SigBox,
  /** 0154: the renter's initials on the clean-up charge line (top) and box 40's X (the due-back time) */
  initialsCleanup: { box: 'cleanup', x: 262, top: 129, w: 54, h: 11.5 } as SigBox,
  initialsDue: { box: '40-x', x: 452, top: 430, w: 48, h: 11 } as SigBox
};
/** The date the renter signed, in the empty space right of box 20's signature line (the form has no date box). */
export const SIGNED_ON = { label: { x: 237, y: 774, size: 5 }, date: { x: 237, y: 781.5, size: 6.5 }, w: 48 };
/** "2026-10-01": a signature's day in Toronto. */
export function signedDay(iso: string | null | undefined): string | null {
  if (!iso || Number.isNaN(new Date(iso).getTime())) return null;
  const p = parts(iso);
  return `${p.y}-${p.m}-${p.d}`;
}

const S = 8; // the size of most values
const T = (box: string, text: string | null | undefined, x: number, y: number, w: number, o: Partial<Text> = {}): Text | null =>
  text && String(text).trim() ? { box, text: String(text).trim(), x, y, w, size: o.size ?? S, ...o } : null;

// ---------------------------------------------------------------- formatting
const TZ = 'America/Toronto';
const parts = (iso: string) => {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: 'numeric', minute: '2-digit', hour12: true })
    .formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return { y: p.year!, m: p.month!, d: p.day!, time: `${p.hour}:${p.minute}`, pm: /p/i.test(p.dayPeriod ?? '') };
};
/** "Jun 16, 2027 10:00 AM" in Toronto time */
export function dateTime(iso: string): string {
  const d = new Date(iso);
  const date = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, month: 'short', day: 'numeric', year: 'numeric' }).format(d);
  const p = parts(iso);
  return `${date} ${p.time} ${p.pm ? 'PM' : 'AM'}`;
}
/** Dollars with cents, "$1,234.50"; "-$10.00" below zero (the form's own fonts have no minus sign). */
export function dollars(cents: number | null | undefined): string {
  if (cents === null || cents === undefined) return '';
  const s = (Math.abs(cents) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return `${cents < 0 ? '-' : ''}$${s}`;
}
export function phone(v: string | null | undefined): string {
  if (!v) return '';
  const d = v.replace(/\D/g, '');
  const n = d.length === 11 && d.startsWith('1') ? d.slice(1) : d;
  return n.length === 10 ? `(${n.slice(0, 3)}) ${n.slice(3, 6)}-${n.slice(6)}` : v;
}
const dayParts = (d: string | null | undefined) => (d && /^\d{4}-\d{2}-\d{2}/.test(d) ? { y: d.slice(0, 4), m: d.slice(5, 7), d: d.slice(8, 10) } : null);
/** Age in whole years on a day (the pickup) */
export function ageOn(dob: string | null | undefined, onIso: string): number | null {
  const b = dayParts(dob);
  if (!b) return null;
  const o = parts(onIso);
  let a = Number(o.y) - Number(b.y);
  if (Number(o.m) < Number(b.m) || (Number(o.m) === Number(b.m) && Number(o.d) < Number(b.d))) a--;
  return a >= 0 && a < 130 ? a : null;
}
const postal = (p: string | null | undefined) => {
  const c = (p ?? '').replace(/\s/g, '').toUpperCase();
  return /^[A-Z]\d[A-Z]\d[A-Z]\d$/.test(c) ? `${c.slice(0, 3)} ${c.slice(3)}` : (p ?? '').toUpperCase();
};
/** "2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2": the one-line mailing address in the form's capitals. */
export function mailingLine(m: BlindSpotFacts['extra']['mailing']): string {
  const city = [m.city, [m.province, postal(m.postal_code)].filter(Boolean).join(' ')].filter((x) => x && x.trim()).join(', ');
  const built = [m.street, m.unit ? `Unit ${m.unit}` : null, city].filter((x) => x && x.trim()).join(', ');
  return (built || m.line || '').toUpperCase();
}
/** The street and unit, as box 15 printed the old address ("104 Crockford Blvd"). */
export function mailingStreet(m: BlindSpotFacts['extra']['mailing']): string {
  return [m.street, m.unit ? `Unit ${m.unit}` : null].filter((x) => x && x.trim()).join(', ') || (m.line ?? '').split(',').slice(0, 2).join(',').trim();
}

// ---------------------------------------------------------------- the booking in the boxes
export interface Layout { texts: Text[]; dots: Dot[]; covers: Cover[] }

const YOUNG = /^young_driver/;
const RENTAL = new Set(['rental_charge']);
const FUEL = new Set(['fuel', 'fuel_service_fee', 'recharging']);
const DAMAGE = /^(damage|deductible)/;
const LATE = new Set(['late_return_extra_days', 'late_return_fee', 'late_return', 'late_return_admin']);
/** The stages of the lines charged before the rental ends (the closing copy adds the return's). */
const PRE = ['booking', 'extension', 'pickup', 'monthly'];
/** The boxes of the vehicle columns: x of the original vehicle (right) and replacement (left) columns. */
const COL = { original: { x: 475, w: 102 }, replacement: { x: 327, w: 86 } };
/** Each row's baseline, from the top of the page (22 to 31). */
const ROW = { '22': 62, '23': 82, make: 103, model: 123, '25': 143.5, '26': 164, '27': 185, '28': 204.5, '29': 224.5, '30': 244.8, '31': 265 };
/** The fuel level, written over the covered gauges: out on the top row, in on the bottom row (baselines). */
export const FUEL_TEXT = { x: 326, w: 128, out: 681.4, in: 691.2 };
/** A fuel reading in words: "Full (100%)", "3/4 (75%)", "Empty (0%)", "About 5/8 (60%)". */
export function fuelText(pct: number | null | undefined): string | null {
  if (pct === null || pct === undefined || !Number.isFinite(Number(pct))) return null;
  const v = Math.max(0, Math.min(100, Math.round(Number(pct))));
  const NAMES: Record<number, string> = { 0: 'Empty', 25: '1/4', 50: '1/2', 75: '3/4', 100: 'Full' };
  const q = Math.round(v / 12.5) * 12.5;
  const name = NAMES[v] ?? (q === 0 ? 'Near empty' : q === 100 ? 'Near full' : Number.isInteger(q / 25) ? `About ${NAMES[q]}` : `About ${q / 12.5}/8`);
  return `${name} (${v}%)`;
}
const kmText = (n: number | null | undefined) => (n === null || n === undefined ? null : `${n.toLocaleString('en-CA')} km`);

/** What goes in each box of page 1 for a booking (the unsigned document; signatures are added by fill.ts). */
export function layout(f: BlindSpotFacts): Layout {
  const b = f.booking; const r = f.renter; const v = f.vehicle; const x = f.extra;
  const me = f.drivers.find((d) => d.role === 'renter');
  const others = f.drivers.filter((d) => d.role === 'additional');
  const t: Array<Text | null> = [];
  const dots: Dot[] = [];
  const days = Math.max(0, Number(b.billable_days) || 0);

  // header: the mailing address, the HST number, the agreement number (the booking number)
  t.push(T('address', mailingLine(x.mailing), 49, 94, 250, { size: 12 }));
  t.push(T('1', x.hst_number, 64, 120.5, 155, { size: 11 }));
  t.push(T('ra', b.booking_number, 340, 23.5, 140, { size: 10, bold: true }));

  // the car (the original vehicle: the car rented; the replacement column is for a car swapped during the rental)
  // a car swapped during the rental: the original vehicle is the car it started with, the replacement the car now
  const mx = x.more ?? null;
  const swap = mx?.swaps?.length ? mx.swaps[mx.swaps.length - 1]! : null;
  const first: { plate: string | null; make: string; model: string; year: number; trim: string | null; fleet_number?: string | null } | null = swap ? mx!.swaps[0]!.from : v;
  const firstFleet = swap ? mx!.swaps[0]!.from.fleet_number : x.fleet_number;
  t.push(T('22', firstFleet, 488, ROW['22'], 89));
  t.push(T('23', first?.plate?.toUpperCase(), 488, ROW['23'], 89));
  t.push(T('24-make', first?.make, 488, ROW.make, 89));
  t.push(T('24-model', first ? [first.year, first.model, first.trim].filter(Boolean).join(' ') : null, 488, ROW.model, 89));
  const pick = mx?.pickup ?? null;
  const out = pick ? pick.at : b.pickup_at;
  t.push(T('26', dateTime(out), COL.original.x, ROW['26'], COL.original.w, { size: 7.5 }));
  const kmOut = pick ? pick.odometer_km : x.odometer_out_km;
  t.push(T('28', kmText(kmOut), COL.original.x, ROW['28'], COL.original.w));
  t.push(T('30', b.km_allowance_total != null ? `${b.km_allowance_total.toLocaleString('en-CA')} km` : null, COL.original.x, ROW['30'], COL.original.w));
  const back = mx?.return ?? null;
  if (swap) {
    const to: AgreementVehicle = swap.to;
    const R2 = COL.replacement;
    t.push(T('r-22', to.fleet_number, R2.x, ROW['22'], R2.w));
    t.push(T('r-23', to.plate?.toUpperCase(), R2.x, ROW['23'], R2.w));
    t.push(T('r-24-make', to.make, R2.x, ROW.make, R2.w));
    t.push(T('r-24-model', [to.year, to.model, to.trim].filter(Boolean).join(' '), R2.x, ROW.model, R2.w));
    // the original car came back at the swap; the replacement went out then
    t.push(T('25', dateTime(swap.at), COL.original.x, ROW['25'], COL.original.w, { size: 7.5 }));
    t.push(T('27', kmText(swap.from_km_in), COL.original.x, ROW['27'], COL.original.w));
    if (swap.from_km_in !== null && kmOut !== null && kmOut !== undefined) t.push(T('29', kmText(swap.from_km_in - kmOut), COL.original.x, ROW['29'], COL.original.w));
    t.push(T('r-26', dateTime(swap.at), R2.x, ROW['26'], R2.w, { size: 7 }));
    t.push(T('r-28', kmText(swap.to_km_out), R2.x, ROW['28'], R2.w));
    if (back) {
      t.push(T('r-25', dateTime(back.at), R2.x, ROW['25'], R2.w, { size: 7 }));
      t.push(T('r-27', kmText(back.odometer_km), R2.x, ROW['27'], R2.w));
      if (swap.to_km_out !== null) t.push(T('r-29', kmText(back.odometer_km - swap.to_km_out), R2.x, ROW['29'], R2.w));
      t.push(T('31', kmText(back.km_charged), COL.original.x, ROW['31'], COL.original.w));
    }
  } else if (back) {
    t.push(T('25', dateTime(back.at), COL.original.x, ROW['25'], COL.original.w, { size: 7.5 }));
    t.push(T('27', kmText(back.odometer_km), COL.original.x, ROW['27'], COL.original.w));
    t.push(T('29', kmText(back.km_driven), COL.original.x, ROW['29'], COL.original.w));
    t.push(T('31', kmText(back.km_charged), COL.original.x, ROW['31'], COL.original.w));
  }
  t.push(T('32', b.km_allowance_per_day != null ? `${b.km_allowance_per_day} km` : null, 444, 285.5, 55, { size: 7 }));

  // the renter
  t.push(T('3', r?.legal_name ?? me?.full_name, 22, 183.5, 220));
  t.push(T('3-cell', phone(r?.mobile), 246, 183.5, 75));
  t.push(T('4', r ? [r.address_line1, r.address_line2].filter((s) => s && s.trim()).join(', ') : null, 22, 204.5, 220));
  t.push(T('5-city', r?.city, 22, 224.5, 66));
  t.push(T('5-prov', r?.province, 90, 224.5, 62));
  t.push(T('5-postal', r?.postal_code ? postal(r.postal_code) : null, 155, 224.5, 86));
  const dob = r?.date_of_birth ?? me?.date_of_birth ?? null;
  t.push(T('8-dob', dayParts(dob) ? dob!.slice(0, 10) : null, 262, 264.5, 59));
  t.push(T('9', me?.licence_number?.toUpperCase(), 22, 285.5, 136));
  t.push(T('9-prov', me?.licence_issuer, 161, 285.5, 37));
  const ex = dayParts(me?.licence_expiry);
  if (ex) {
    t.push(T('9-y', ex.y, 235, 285.5, 22, { align: 'center' }));
    t.push(T('9-m', ex.m, 263, 285.5, 12, { align: 'center' }));
    t.push(T('9-d', ex.d, 282, 285.5, 10, { align: 'center' }));
  }
  const age = ageOn(dob, b.pickup_at);
  t.push(T('9-age', age != null ? String(age) : null, 305.5, 285.5, 30, { align: 'center' }));

  // additional renters: every name in box 10, the first one's licence in box 11 (the others' in box 14)
  t.push(T('10', others.map((d) => d.full_name).join('; '), 22, 325.5, 174));
  const a1 = others[0];
  if (a1) {
    t.push(T('11', a1.licence_number?.toUpperCase(), 22, 346.5, 136));
    t.push(T('11-prov', a1.licence_issuer, 161, 346.5, 36));
    const e1 = dayParts(a1.licence_expiry);
    if (e1) {
      t.push(T('11-y', e1.y, 234, 346.5, 22, { align: 'center' }));
      t.push(T('11-m', e1.m, 256, 346.5, 12, { align: 'center' }));
      t.push(T('11-d', e1.d, 273, 346.5, 10, { align: 'center' }));
    }
  }

  // to be paid by: an insurance replacement rental (a booking billed to an insurer)
  const ins = x.insurer;
  const pol = x.more?.insurer_policy ?? null;
  if (ins) {
    t.push(T('insured', pol?.insured_vehicle, 22, 384, 296));
    t.push(T('claim', ins.claim_number, 22, 407.5, 296));
    t.push(T('adjuster', [ins.adjuster_name, phone(ins.adjuster_phone)].filter(Boolean).join(', '), 22, 427, 264));
    t.push(T('12', ins.name, 22, 447.5, 264));
    t.push(T('13', pol?.policy_number, 22, 468, 145));
    t.push(T('13-prov', pol?.province, 172, 468, 60));
    t.push(T('13-expiry', pol?.expiry?.slice(0, 10), 236, 468, 50, { size: 7 }));
  } else if (b.coverage_option === 1 && x.coverage) {
    // OPCF 27: the renter's own insurer and policy, the one a claim on the car goes to
    t.push(T('12', x.coverage.insurer_name ? `${x.coverage.insurer_name} (renter's OPCF 27)` : null, 22, 447.5, 264));
    t.push(T('13', x.coverage.policy_number, 22, 468, 145));
    t.push(T('13-expiry', x.coverage.policy_expiry?.slice(0, 10), 236, 468, 50, { size: 7 }));
  } else if (b.coverage_option === 2) {
    // 0178: card coverage: the insurer behind the card (usually Assurant) and the card that carries the coverage
    const cv = x.coverage ?? null;
    const card = cv?.card_issuer ? `${cv.card_issuer} card${cv.card_last4 ? ` ending ${cv.card_last4}` : ''}` : f.card ? `${f.card.brand.toUpperCase()} card ending ${f.card.last4}` : null;
    t.push(T('12', cv?.coverage_provider ? `${cv.coverage_provider} (credit card rental coverage)` : card ? 'Credit card rental coverage' : null, 22, 447.5, 264));
    t.push(T('13', card, 22, 468, 145));
  } else if (b.coverage_option === 3) {
    // 0178: the CarmaCars Protection Plan bought with the rental: the plan and its activation reference (else the agreement)
    t.push(T('12', 'CarmaCars Protection Plan (rental coverage)', 22, 447.5, 264));
    t.push(T('13', x.coverage?.activation_ref ?? (b.agreement_number ? `With agreement ${b.agreement_number}` : null), 22, 468, 145));
  } else if (b.coverage_option === 4) {
    t.push(T('12', 'Insurance included with the car', 22, 447.5, 264));
  }

  const more = x.more ?? null;
  // every line of the version (booking and extension stages; the return stage on the closing copy)
  const all = more ? more.lines.filter((l) => more.return ? true : PRE.includes(l.stage)) : f.lines.map((l) => ({ ...l, hst_cents: 0, stage: 'booking' }));
  // the rates (33 to 38): COUNT @ RATE = AMOUNT on the row of the rate, so the count times the rate is the amount. The
  // weeks or months row when the weekly or monthly rate makes the charge exactly; otherwise the days row at the daily
  // (or 3+ day) rate, or, when no one rate makes it (a monthly or weekly rate counted by the day, daily and weekend
  // days, a charge agreed by hand), at the rental charge divided by the days, rounded to the cent, and box 14 says how
  // the charge was made. Box 39 is the sum of the amounts of these rows.
  const sumOf = (pred: (c: string) => boolean, ls: Array<{ charge_type: string; amount_cents: number }> = all) => ls.filter((l) => pred(l.charge_type)).reduce((t2, l) => t2 + l.amount_cents, 0);
  const rental = sumOf((c) => RENTAL.has(c)) || b.rental_charge_cents;
  let rateRows = 0;
  const R = (box: string, y: number, count: string | null, rate: number | null, amount: number | null) => {
    t.push(T(`${box}-count`, count, 404, y, 78, { align: 'right' }));
    t.push(T(`${box}-rate`, rate != null ? dollars(rate) : null, 415, y, 62));
    t.push(T(`${box}-amount`, amount ? dollars(amount) : null, 577, y, 72, { align: 'right' }));
    rateRows += amount ?? 0;
  };
  const ret = more?.return ?? null;
  const overage = sumOf((c) => c === 'mileage_overage');
  const lateFee = sumOf((c) => c === 'late_return_fee' || c === 'late_return' || c === 'late_return_admin');
  const extraDays = sumOf((c) => c === 'late_return_extra_days');
  // 33: the rate per kilometre over the allowance; on the closing copy the kilometres charged and their amount
  if (b.overage_cents_per_km != null || ret) R('33', 305.5, ret ? (ret.km_charged ?? 0).toLocaleString('en-CA') : null, b.overage_cents_per_km, ret ? overage : null);
  const ra = b.rate_applied ?? 'daily';
  let rateNote: string | null = null;
  if (rental > 0) {
    const perDay = ra === 'multi_day' ? b.multi_day_rate_cents ?? null : ra === 'daily' || ra === 'weekend' ? b.daily_rate_cents : null;
    if (ra === 'weekly' && days > 0 && days % 7 === 0 && b.weekly_rate_cents && (days / 7) * b.weekly_rate_cents === rental) R('36', 366.5, String(days / 7), b.weekly_rate_cents, rental);
    else if (ra === 'monthly' && days > 0 && days % 30 === 0 && b.monthly_rate_cents && (days / 30) * b.monthly_rate_cents === rental) R('37', 387, String(days / 30), b.monthly_rate_cents, rental);
    else if (days > 0 && perDay && days * perDay === rental) R('35', 346, String(days), perDay, rental);
    else if (days > 0) {
      const each = Math.round(rental / days);
      R('35', 346, String(days), each, rental);
      const how = ra === 'monthly' && b.monthly_rate_cents ? `the monthly rate ${dollars(b.monthly_rate_cents)} / 30 x ${days} days`
        : ra === 'weekly' && b.weekly_rate_cents ? `the weekly rate ${dollars(b.weekly_rate_cents)} / 7 x ${days} days`
        : (ra === 'daily' || ra === 'weekend') && b.daily_days != null && b.weekend_days != null && b.daily_rate_cents && b.weekend_rate_cents
          ? `${b.daily_days} days x ${dollars(b.daily_rate_cents)} + ${b.weekend_days} weekend days x ${dollars(b.weekend_rate_cents)}`
        : 'the rental charge agreed';
      rateNote = `Box 35: ${how} = ${dollars(rental)}, ${dollars(each)} a day${each * days === rental ? '' : ' rounded'}.`;
    } else R('35', 346, null, null, rental);
  }
  // the closing copy: the hours late (34), the extra days (38)
  if (ret) {
    if (ret.late_hours || lateFee) R('34', 326, ret.late_hours ? `${ret.late_hours}` : null, null, lateFee || null);
    if (extraDays) {
      const n = ret.extra_days ?? 0;
      R('38', 407.5, n ? String(n) : null, n ? (b.daily_rate_cents && n * b.daily_rate_cents === extraDays ? b.daily_rate_cents : Math.round(extraDays / n)) : null, extraDays);
    }
  }
  if (rateRows > 0) t.push(T('39', dollars(rateRows), 577, 427, 72, { align: 'right' }));

  // 14, additional information: what has no box of its own
  const info: string[] = [];
  if (ins && ins.authorized_days) info.push(`Insurer authorized ${ins.authorized_days} day${ins.authorized_days === 1 ? '' : 's'}${ins.authorized_daily_rate_cents ? ` at ${dollars(ins.authorized_daily_rate_cents)}/day` : ''}.`);
  for (const d of others.slice(1)) if (d.licence_number) info.push(`${d.full_name}: licence ${d.licence_number.toUpperCase()}${d.licence_issuer ? ` (${d.licence_issuer})` : ''}${d.licence_expiry ? `, expires ${d.licence_expiry.slice(0, 10)}` : ''}.`);
  // a line with a box of its own (the rate rows, underage, CDW, winter tires); the others before the rental starts are
  // box 48 (pre adjustment: delivery, add-ons, drivers' fees, a discount, prepaid fuel); after it, damages (52), fuel
  // (53) and the rest (54, post adjustment)
  const ownBox = (c: string) => RENTAL.has(c) || YOUNG.test(c) || c === 'coverage_sold' || c === 'vlf' || c === 'winter_tire' || c === 'deposit' || c === 'mileage_overage' || LATE.has(c);
  const isPre = (l: { stage?: string }) => PRE.includes(l.stage ?? 'booking');
  const preAdjust = all.filter((l) => isPre(l) && !ownBox(l.charge_type));
  const damages = all.filter((l) => !isPre(l) && !ownBox(l.charge_type) && DAMAGE.test(l.charge_type));
  const fuels = all.filter((l) => !isPre(l) && !ownBox(l.charge_type) && FUEL.has(l.charge_type));
  const postAdjust = all.filter((l) => !isPre(l) && !ownBox(l.charge_type) && !DAMAGE.test(l.charge_type) && !FUEL.has(l.charge_type));
  if (rateNote) info.push(rateNote);
  if (preAdjust.length) info.push(`Box 48: ${preAdjust.map((l) => `${l.description} ${dollars(l.amount_cents)}`).join('; ')}.`);
  if (postAdjust.length) info.push(`Box 54: ${postAdjust.map((l) => `${l.description} ${dollars(l.amount_cents)}`).join('; ')}.`);
  if ([...damages, ...fuels, ...postAdjust].some((l) => ((l as { hst_cents?: number }).hst_cents ?? 0) !== 0)) info.push('Boxes 52 to 54 include their HST.');
  // the coverage and how the deposit and rental are paid
  const cov = x.coverage;
  if (b.coverage_option === 2 && cov) info.push(`Coverage: card${cov.card_issuer ? ` (${cov.card_issuer}${cov.card_last4 ? ` ending ${cov.card_last4}` : ''})` : ''}.`);
  if (b.coverage_option === 3) info.push('Coverage: CarmaCars Protection Plan (CDW).');
  if (b.coverage_option === 4) info.push('Coverage: included with the car.');
  if (more) {
    const d = more.deposit;
    if (d.amount_cents && (d.method === 'offline' || d.pay_method === 'cash' || d.pay_method === 'e_transfer')) info.push(`Deposit ${dollars(d.amount_cents)} by ${(d.paid_method ?? d.pay_method) === 'cash' ? 'cash' : 'e-Transfer'}.`);
    const offline = more.payments.filter((p) => p.purpose !== 'deposit' && p.method !== 'card');
    if (offline.length) info.push(`Paid: ${offline.map((p) => `${dollars(p.amount_cents)} ${p.method === 'cash' ? 'cash' : p.method === 'e_transfer' ? 'e-Transfer' : p.method.replace(/_/g, ' ')}`).join('; ')}.`);
  }
  // up to three lines of about 70 characters at this size
  const words = info.join(' ').split(/\s+/).filter(Boolean);
  const rows: string[] = [];
  for (const w of words) { const last = rows[rows.length - 1]; if (last !== undefined && (last + ' ' + w).length <= 78) rows[rows.length - 1] = last + ' ' + w; else rows.push(w); }
  rows.slice(0, 4).forEach((row, i) => t.push(T(`14-${i + 1}`, i === 3 && rows.length > 4 ? row + ' ...' : row, 22, 487 + i * 7.4, 264, { size: 6.5 })));

  // 15: rented from and to be returned to, the mailing address (in place of the old one); no destination is recorded
  t.push(T('15-from', mailingStreet(x.mailing), 22, 529.6, 90, { size: 6 }));
  t.push(T('15-to', mailingStreet(x.mailing), 207.5, 529.6, 80, { size: 6 }));

  // 18: the card on file (its last four digits after the printed XXXX XXXX XXXX)
  if (f.card?.last4) t.push(T('18-card', `${f.card.last4}${f.card.brand ? ` (${f.card.brand.charAt(0).toUpperCase()}${f.card.brand.slice(1)})` : ''}`, 172, 669.5, 110, { size: 7 }));
  if (f.card?.last4 && x.card_expiry) t.push(T('18-expiry', x.card_expiry, 140, 679, 80, { size: 7 }));


  // 40: due back, the date under M, DD and YYYY (in place of the printed "T B D"), the time, AM or PM
  const due = parts(b.return_at);
  t.push(T('40-m', due.m, 302, 448, 14, { align: 'center', size: 7 }));
  t.push(T('40-d', due.d, 326, 448, 14, { align: 'center', size: 7 }));
  t.push(T('40-y', due.y, 352, 448, 22, { align: 'center', size: 7 }));
  t.push(T('40-time', due.time, 362, 448, 16, { size: 6.5 }));
  dots.push({ box: due.pm ? '40-pm' : '40-am', x: 408.4, y: due.pm ? 444.6 : 435.8, r: 2.4 });

  // other taxable charges: underage fee, CDW (the coverage sold), winter tires; the rate per day when it divides evenly
  const fee = (box: string, y: number, cents: number) => {
    if (!cents) return;
    if (days > 0 && cents % days === 0) t.push(T(`${box}-rate`, dollars(cents / days), 448, y, 38, { size: 7 }));
    t.push(T(`${box}-amount`, dollars(cents), 577, y, 72, { align: 'right' }));
  };
  fee('42', 467, sumOf((c) => YOUNG.test(c)));
  fee('cdw', 487.5, sumOf((c) => c === 'coverage_sold'));
  // 43, VLF $ per day (0195): the vehicle licensing fee of an insurer-billed rental
  const vlf = sumOf((c) => c === 'vlf');
  fee('43', 508, vlf);
  fee('44', 529, sumOf((c) => c === 'winter_tire'));
  // 48, pre adjustment: the charges with no box of their own (delivery, add-ons, drivers, a discount), so 49 adds up
  const pre = preAdjust.reduce((t2, l) => t2 + l.amount_cents, 0);
  if (pre) t.push(T('48', dollars(pre), 577, 610, 72, { align: 'right' }));

  // the totals. 49: every charge before tax but damages, fuel and the post adjustment; 50: its HST (13% of box 49, the
  // HST charged on those lines); 52, 53, 54 (the closing copy): each with its own HST, as the form adds them after the
  // tax; 55: the total charged. 49 + 50 + 52 + 53 + 54 = 55.
  const lines = more ? all : null;
  const after = new Set([...damages, ...fuels, ...postAdjust]);
  const in49 = lines ? lines.filter((l) => !after.has(l)) : null;
  const withHst = (ls: Array<{ amount_cents: number; hst_cents: number }>) => ls.reduce((t2, l) => t2 + l.amount_cents + l.hst_cents, 0);
  const allTotal = lines ? withHst(lines) : b.total_due_at_booking_cents;
  t.push(T('49', dollars(in49 ? in49.reduce((t2, l) => t2 + l.amount_cents, 0) : b.subtotal_at_booking_cents), 577, 630.5, 72, { align: 'right' }));
  t.push(T('50', dollars(in49 ? in49.reduce((t2, l) => t2 + l.hst_cents, 0) : b.hst_at_booking_cents), 577, 650.5, 72, { align: 'right' }));
  if (lines) {
    const dmg = withHst(damages as Array<{ amount_cents: number; hst_cents: number }>); const fuel = withHst(fuels as Array<{ amount_cents: number; hst_cents: number }>);
    const post = withHst(postAdjust as Array<{ amount_cents: number; hst_cents: number }>);
    if (dmg) t.push(T('52', dollars(dmg), 577, 671, 72, { align: 'right', size: 7 }));
    if (fuel) t.push(T('53', dollars(fuel), 577, 690, 72, { align: 'right' }));
    if (post) t.push(T('54', dollars(post), 577, 711, 72, { align: 'right' }));
  }
  t.push(T('55', dollars(allTotal), 577, 731.5, 72, { align: 'right', bold: true }));
  if (b.deposit_cents > 0) t.push(T('56', dollars(b.deposit_cents), 577, 751.5, 72, { align: 'right' }));
  // 59, deposit received: the deposit taken (a card hold, a charge, cash or e-Transfer) and the month and day it was
  // taken; before it is taken, the amount due at pickup, said so. The add deposit rows are for a second deposit: blank.
  const dep = more?.deposit ?? null;
  const depPaid = more ? more.payments.filter((p) => p.purpose === 'deposit' && p.amount_cents > 0) : [];
  const taken = !!dep && (['held', 'captured', 'settled', 'carried_forward'].includes(dep.status ?? '') || (dep.method === 'offline' && !!dep.paid_method));
  const received = taken ? { cents: dep!.amount_cents || b.deposit_cents, at: dep!.taken_at ?? depPaid[depPaid.length - 1]?.at ?? null }
    : depPaid.length ? { cents: depPaid.reduce((t2, p) => t2 + p.amount_cents, 0), at: depPaid[depPaid.length - 1]!.at ?? null } : null;
  if (received && received.cents > 0) {
    t.push(T('deposit-received', dollars(received.cents).replace('$', ''), 374, 707.4, 57, { size: 7.5 }));
    if (received.at && !Number.isNaN(new Date(received.at).getTime())) {
      const d = parts(received.at);
      t.push(T('59-m', d.m, 303, 707.4, 22, { align: 'center', size: 7.5 }));
      t.push(T('59-d', d.d, 327, 707.4, 18, { align: 'center', size: 7.5 }));
    }
  } else if (b.deposit_cents > 0) t.push(T('deposit-due', `${dollars(b.deposit_cents).replace('$', '')} due at pickup`, 374, 707.4, 57, { size: 7.5 }));
  if (more && ret) {
    const paid = more.payments.filter((p) => p.purpose !== 'deposit').reduce((t2, p) => t2 + p.amount_cents, 0);
    const balance = allTotal - paid;
    t.push(T('57', dollars(Math.abs(balance)), 577, 771, 72, { align: 'right' }));
    if (balance !== 0) dots.push({ box: balance > 0 ? '57-renter' : '57-company', x: balance > 0 ? 435.3 : 363.3, y: 764.5, r: 2.6 });
    if (paid) {
      t.push(T('paid', dollars(paid).replace('$', ''), 577, 791, 62, { align: 'right' }));
      const methods = new Set(more.payments.filter((p) => p.purpose !== 'deposit' && p.amount_cents > 0).map((p) => p.method));
      dots.push({ box: methods.size === 1 && methods.has('cash') ? 'paid-cash' : methods.size === 1 && methods.has('cheque') ? 'paid-cheque' : 'paid-other', x: 509.3,
        y: methods.size === 1 && methods.has('cash') ? 804 : methods.size === 1 && methods.has('cheque') ? 812.5 : 821.1, r: 2 });
      if (!(methods.size === 1 && (methods.has('cash') || methods.has('cheque')))) t.push(T('paid-how', [...methods].map((m) => (m === 'card' ? 'card' : m === 'e_transfer' ? 'e-Transfer' : m.replace(/_/g, ' '))).join(', '), 515, 823.5, 62, { size: 6 }));
    }
    if (more.deposit.released_cents) t.push(T('refund', dollars(more.deposit.released_cents).replace('$', ''), 446, 797, 55, { size: 7.5 }));
  }
  // the fuel: out (the check-out report), in (the check-in report), in words over the covered gauges; blank with no reading
  t.push(T('fuel-out', fuelText(more?.pickup?.fuel_pct), FUEL_TEXT.x, FUEL_TEXT.out, FUEL_TEXT.w, { size: 7 }));
  t.push(T('fuel-in', fuelText(ret?.fuel_pct), FUEL_TEXT.x, FUEL_TEXT.in, FUEL_TEXT.w, { size: 7 }));

  // the old address, Blind Spot's HST number and the old signature are always covered (blank until replaced)
  // 0178, the owner: "Every box needs to be filled out": a box that does not apply to this rental says N/A (a box left
  // blank reads as unknown). Only boxes that do not apply: a value the rental should have and lacks stays blank (the
  // Agreement card asks for it). Each N/A is its own box name ("-na"), so a missing value is never mistaken for one.
  const has = new Set(t.filter((v2): v2 is Text => !!v2).map((v2) => v2.box));
  const NA = (box: string, x0: number, y: number, w: number, o: Partial<Text> = {}) => { if (!has.has(box)) t.push(T(`${box}-na`, 'N/A', x0, y, w, { size: 7, ...o })); };
  // not collected: P.O. number, home and office phone, employer, a new or temporary address, the destination
  NA('2', 258, 119, 60); NA('3-home', 246, 204.5, 75); NA('7', 22, 245.5, 200); NA('7-office', 246, 245.5, 75); NA('8', 22, 264.5, 200); NA('15-dest', 118, 529.6, 80, { size: 6 });
  // no additional driver; no car swapped (the replacement vehicle column)
  if (!others.length) { NA('10', 22, 325.5, 174); NA('11', 22, 346.5, 136); }
  if (!swap) NA('r-22', COL.replacement.x, ROW['22'], COL.replacement.w);
  // not an insurance replacement rental: the insured vehicle, the claim and the adjuster
  if (!ins) { NA('insured', 22, 384, 296); NA('claim', 22, 407.5, 296); NA('adjuster', 22, 427, 264); }
  // box 13's province and expiry belong to a policy (insurer, OPCF 27): not to card coverage, the plan or included insurance
  if (!ins && b.coverage_option !== 1) { NA('13-prov', 172, 468, 60); NA('13-expiry', 236, 468, 50); }
  // the optional charges not on this rental: underage, CDW, VLF, winter tires, LDW, T&LDW, PAP/PEC, Waiver Saver
  NA('42-amount', 577, 467, 72, { align: 'right' }); NA('cdw-amount', 577, 487.5, 72, { align: 'right' }); if (!vlf) NA('43', 577, 508, 72, { align: 'right' });
  NA('44-amount', 577, 529, 72, { align: 'right' }); NA('45', 577, 549, 72, { align: 'right' }); NA('46', 577, 569.5, 72, { align: 'right' });
  NA('47', 577, 590, 72, { align: 'right' }); NA('waiver', 409, 607, 28);
  return { texts: t.filter((v2): v2 is Text => !!v2), dots, covers: COVERS };
}
