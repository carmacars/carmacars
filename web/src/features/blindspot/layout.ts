// The Blind Spot Car Rental agreement (CarmaCars rents under Blind Spot's insurance): the second rental agreement of a
// booking, beside CarmaCars' own (docs/changes/2026-10-23-second-rental-agreement.md). The template is Blind Spot's own
// two-page form (Admin > Settings > Forms); it has no fillable field, so each value is drawn in its box at the place
// measured on the form (A4, 595.28 x 841.89 points). Coordinates here are from the top of the page, in points.
// This file maps a booking to what goes in each box; fill.ts draws it. Never invents: a box with no value stays blank.
// Relative imports with their extension: the unit tests run this file in Node directly.

export const PAGE_H = 841.89;
export const PINK = { r: 255 / 255, g: 186 / 255, b: 204 / 255 };
export const WHITE = { r: 1, g: 1, b: 1 };

/** The facts of a booking for the form: the rental agreement's own (public.server_agreement_facts) and the extra ones
 *  of public.server_blindspot_facts (the mailing address, the HST number, the insurer, the odometer, the template). */
export interface BlindSpotFacts {
  booking: {
    booking_number: string; agreement_number: string | null; pickup_at: string; return_at: string; billable_days: number;
    rate_applied: string | null; daily_rate_cents: number | null; weekend_rate_cents: number | null; weekly_rate_cents: number | null;
    monthly_rate_cents: number | null; multi_day_rate_cents?: number | null; rental_charge_cents: number; km_allowance_per_day: number | null;
    km_allowance_total: number | null; overage_cents_per_km: number | null; deposit_cents: number; subtotal_at_booking_cents: number;
    hst_at_booking_cents: number; total_due_at_booking_cents: number;
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
  };
}

export type Align = 'left' | 'right' | 'center';
/** A value in a box: x is the left edge (the right edge when right-aligned, the centre when centred), y the baseline. */
export interface Text { box: string; text: string; x: number; y: number; w: number; size: number; align?: Align; bold?: boolean }
export interface Cover { box: string; x: number; y: number; w: number; h: number; color: 'white' | 'pink' }
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
  { box: '40', x: 291, y: 440.8, w: 87.5, h: 8.8, color: 'pink' }
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
  company: { box: '21', x: 118, top: 799, w: 165, h: 25 } as SigBox
};

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
const RENTAL = new Set(['rental_charge', 'late_return_extra_days']);

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
  t.push(T('22', x.fleet_number, 488, 62, 89));
  t.push(T('23', v?.plate?.toUpperCase(), 488, 82, 89));
  t.push(T('24-make', v?.make, 488, 103, 89));
  t.push(T('24-model', v ? [v.year, v.model, v.trim].filter(Boolean).join(' ') : null, 488, 123, 89));
  t.push(T('26', dateTime(b.pickup_at), 475, 164, 102, { size: 7.5 }));
  t.push(T('28', x.odometer_out_km != null ? `${x.odometer_out_km.toLocaleString('en-CA')} km` : null, 475, 204.5, 102));
  t.push(T('30', b.km_allowance_total != null ? `${b.km_allowance_total.toLocaleString('en-CA')} km` : null, 475, 244.8, 102));
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
  if (ins) {
    t.push(T('claim', ins.claim_number, 22, 407.5, 296));
    t.push(T('adjuster', [ins.adjuster_name, phone(ins.adjuster_phone)].filter(Boolean).join(', '), 22, 427, 264));
    t.push(T('12', ins.name, 22, 447.5, 264));
  }

  // 14, additional information: what has no box of its own
  const info: string[] = [];
  if (ins && ins.authorized_days) info.push(`Insurer authorized ${ins.authorized_days} day${ins.authorized_days === 1 ? '' : 's'}${ins.authorized_daily_rate_cents ? ` at ${dollars(ins.authorized_daily_rate_cents)}/day` : ''}.`);
  for (const d of others.slice(1)) if (d.licence_number) info.push(`${d.full_name}: licence ${d.licence_number.toUpperCase()}${d.licence_issuer ? ` (${d.licence_issuer})` : ''}${d.licence_expiry ? `, expires ${d.licence_expiry.slice(0, 10)}` : ''}.`);
  const otherLines = f.lines.filter((l) => !RENTAL.has(l.charge_type) && !YOUNG.test(l.charge_type) && l.charge_type !== 'coverage_sold' && l.charge_type !== 'winter_tire' && l.charge_type !== 'deposit');
  if (otherLines.length) info.push(`Other charges: ${otherLines.map((l) => `${l.description} ${dollars(l.amount_cents)}`).join('; ')}.`);
  // up to three lines of about 70 characters at this size
  const words = info.join(' ').split(/\s+/).filter(Boolean);
  const rows: string[] = [];
  for (const w of words) { const last = rows[rows.length - 1]; if (last !== undefined && (last + ' ' + w).length <= 72) rows[rows.length - 1] = last + ' ' + w; else rows.push(w); }
  rows.slice(0, 3).forEach((row, i) => t.push(T(`14-${i + 1}`, i === 2 && rows.length > 3 ? row + ' ...' : row, 22, 490 + i * 8.6, 264, { size: 7 })));

  // 15: rented from and to be returned to, the mailing address (in place of the old one); no destination is recorded
  t.push(T('15-from', mailingStreet(x.mailing), 22, 529.6, 90, { size: 6 }));
  t.push(T('15-to', mailingStreet(x.mailing), 207.5, 529.6, 80, { size: 6 }));

  // 18: the card on file (its last four digits after the printed XXXX XXXX XXXX)
  if (f.card?.last4) t.push(T('18-card', `${f.card.last4}${f.card.brand ? ` (${f.card.brand.charAt(0).toUpperCase()}${f.card.brand.slice(1)})` : ''}`, 172, 669.5, 110, { size: 7 }));

  // the rates (33 to 38): the rental charge on the row of its rate, with the count and the rate when they make it
  const rental = f.lines.filter((l) => RENTAL.has(l.charge_type)).reduce((s, l) => s + l.amount_cents, 0) || b.rental_charge_cents;
  const R = (box: string, y: number, count: string | null, rate: number | null, amount: number | null) => {
    t.push(T(`${box}-count`, count, 404, y, 78, { align: 'right' }));
    t.push(T(`${box}-rate`, rate != null ? dollars(rate) : null, 415, y, 62));
    t.push(T(`${box}-amount`, amount != null ? dollars(amount) : null, 577, y, 72, { align: 'right' }));
  };
  if (b.overage_cents_per_km != null) R('33', 305.5, null, b.overage_cents_per_km, null);
  const ra = b.rate_applied ?? 'daily';
  if (rental > 0) {
    if (ra === 'weekly' && days % 7 === 0 && b.weekly_rate_cents && (days / 7) * b.weekly_rate_cents === rental) R('36', 366.5, String(days / 7), b.weekly_rate_cents, rental);
    else if (ra === 'monthly' && days % 30 === 0 && b.monthly_rate_cents && (days / 30) * b.monthly_rate_cents === rental) R('37', 387, String(days / 30), b.monthly_rate_cents, rental);
    else {
      const perDay = ra === 'multi_day' ? b.multi_day_rate_cents ?? null : b.daily_rate_cents;
      R('35', 346, days ? String(days) : null, perDay && days * perDay === rental ? perDay : null, rental);
    }
    t.push(T('39', dollars(rental), 577, 427, 72, { align: 'right' }));
  }

  // 40: due back, the date under M, DD and YYYY (in place of the printed "T B D"), the time, AM or PM
  const due = parts(b.return_at);
  t.push(T('40-m', due.m, 302, 448, 14, { align: 'center', size: 7 }));
  t.push(T('40-d', due.d, 326, 448, 14, { align: 'center', size: 7 }));
  t.push(T('40-y', due.y, 352, 448, 22, { align: 'center', size: 7 }));
  t.push(T('40-time', due.time, 362, 448, 16, { size: 6.5 }));
  dots.push({ box: due.pm ? '40-pm' : '40-am', x: 408.4, y: due.pm ? 444.6 : 435.8, r: 2.4 });

  // other taxable charges: underage fee, CDW (the coverage sold), winter tires; the rate per day when it divides evenly
  const sum = (pred: (c: string) => boolean) => f.lines.filter((l) => pred(l.charge_type)).reduce((s, l) => s + l.amount_cents, 0);
  const fee = (box: string, y: number, cents: number) => {
    if (!cents) return;
    if (days > 0 && cents % days === 0) t.push(T(`${box}-rate`, dollars(cents / days), 448, y, 38, { size: 7 }));
    t.push(T(`${box}-amount`, dollars(cents), 577, y, 72, { align: 'right' }));
  };
  fee('42', 467, sum((c) => YOUNG.test(c)));
  fee('cdw', 487.5, sum((c) => c === 'coverage_sold'));
  fee('44', 529, sum((c) => c === 'winter_tire'));

  // the totals: the subtotal before tax, the HST at 13%, the total, the deposit
  t.push(T('49', dollars(b.subtotal_at_booking_cents), 577, 630.5, 72, { align: 'right' }));
  t.push(T('50', dollars(b.hst_at_booking_cents), 577, 650.5, 72, { align: 'right' }));
  t.push(T('55', dollars(b.total_due_at_booking_cents), 577, 731.5, 72, { align: 'right', bold: true }));
  if (b.deposit_cents > 0) t.push(T('56', dollars(b.deposit_cents), 577, 751.5, 72, { align: 'right' }));

  // the old address, Blind Spot's HST number and the old signature are always covered (blank until replaced)
  return { texts: t.filter((v2): v2 is Text => !!v2), dots, covers: COVERS };
}
