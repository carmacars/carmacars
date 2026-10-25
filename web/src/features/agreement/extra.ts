// What both rental agreements print beyond the booking's own facts (migration 0143, public.server_agreement_extra): the
// deposit and how it is held, how the rental was paid, every price line of every stage, the late terms, the car's fleet
// number and VIN, each driver's address, the insurance replacement's policy, the car swaps, and the pickup and return
// records. Plus a version's header (what changed) and the key terms a signer initials.
// Relative imports with their extension: the unit tests run these files in Node directly.
import { money } from '../../lib/format.ts';

export interface AgreementVehicle { id: string; year: number; make: string; model: string; trim: string | null; colour: string | null; fuel: string | null; plate: string | null; vin: string | null; fleet_number: string | null }
export interface Damage { label: string; location: string | null; description: string | null }
export interface PickupRecord {
  report_id: string; completed: boolean; at: string; odometer_km: number; fuel_pct: number; keys: number | null; staff_user_id: string | null; staff_name: string | null;
  damages: Damage[]; photos: number; vehicle: AgreementVehicle | null;
}
export interface ReturnRecord {
  report_id: string; at: string; odometer_km: number; odometer_out_km: number | null; km_driven: number | null; km_allowed: number | null; km_charged: number;
  fuel_out_pct: number | null; fuel_pct: number; minutes_late: number; late_hours: number; extra_days: number; keys: number | null; cleanliness: string | null;
  staff_user_id: string | null; staff_name: string | null; new_damages: Damage[]; photos: number; vehicle: AgreementVehicle | null;
}
export interface Swap { at: string; reason: string; from: AgreementVehicle; to: AgreementVehicle; from_km_in: number | null; from_fuel_in: number | null; to_km_out: number | null; to_fuel_out: number | null }
export interface Line { charge_type: string; description: string; amount_cents: number; hst_cents: number; stage: string; quantity?: number; unit_amount_cents?: number }
export interface AgreementExtra {
  booking: { status: string; bill_to: string | null; payment_mode: string | null; rental_pay_method: string | null; deposit_pay_method: string | null; agreement_on_paper: boolean | null; handed_over_at: string | null; checked_in_at: string | null };
  vehicle: AgreementVehicle | null;
  original_vehicle: AgreementVehicle | null;
  swaps: Swap[];
  /** by booking driver id */
  drivers: Record<string, { address: string | null; mobile: string | null; email: string | null }>;
  deposit: { amount_cents: number; pay_method: string | null; method: string | null; paid_method: string | null; status: string | null; taken_at: string | null; applied_cents: number; released_cents: number; held_back_cents: number; card_hold_days: number | null };
  payments: Array<{ purpose: string; kind: string; method: string; amount_cents: number; card_brand: string | null; card_last4: string | null; reference: string | null; at: string }>;
  lines: Line[];
  late: { fee_cents: number | null; cap_bps: number | null; grace_minutes: number | null };
  card_expiry?: string | null;
  multi_day_rate_cents?: number | null;
  insurer_policy: { policy_number: string | null; province: string | null; expiry: string | null; insured_vehicle: string | null } | null;
  pickup: PickupRecord | null;
  return: ReturnRecord | null;
}

/** A change between two versions, as the database lists it (app.agreement_changes). */
export interface Change { key: string; label: string; before: string; after: string; material: boolean }
/** The header of a version after the signed original (agreement_versions). */
export interface VersionHeader {
  version_no: number; previous_no: number; kind: 'pickup' | 'return' | 'change' | 'correction'; material: boolean; changes: Change[];
  /** the staff member who countersigns a pickup or return copy */
  countersigned_name?: string | null; countersigned_at?: string | null;
  amendment_number?: string | null;
  /** the signed original: when the renter signed it */
  original_signed_at?: string | null; agreement_number?: string | null;
}

const METHOD: Record<string, string> = { card: 'card', card_hold: 'a hold on the card on file', charged: 'a charge to the card on file, refunded after the return', offline: 'paid another way',
  cash: 'cash', e_transfer: 'Interac e-Transfer', cheque: 'cheque', bank_transfer: 'bank transfer', platform_payout: 'platform payout', insurer: 'billed to the insurer',
  pre_authorized_debit: 'pre-authorized debit', other: 'another way', none: 'no deposit', carried_over: 'carried over from an earlier booking' };
export const methodLabel = (m: string | null | undefined) => (m ? METHOD[m] ?? m.replace(/_/g, ' ') : '');

/** "1/2" style, from a percentage: the nearest eighth, as the gauge reads. */
export function fuelLabel(pct: number | null | undefined): string {
  if (pct === null || pct === undefined) return '';
  const e = Math.round(pct / 12.5);
  const names = ['empty', '1/8', '1/4', '3/8', '1/2', '5/8', '3/4', '7/8', 'full'];
  return `${pct}% (${names[Math.max(0, Math.min(8, e))]})`;
}
export const km = (n: number | null | undefined) => (n === null || n === undefined ? '' : `${n.toLocaleString('en-CA')} km`);
export const carName = (v: AgreementVehicle | null | undefined) => (v ? [v.year, v.make, v.model, v.trim].filter(Boolean).join(' ') : '');

/** How the deposit is held, in words. */
export function depositText(x: AgreementExtra): string {
  const d = x.deposit;
  if (!d.amount_cents) return 'No deposit';
  const how = d.method === 'offline' ? methodLabel(d.paid_method) : d.method ? methodLabel(d.method)
    : d.pay_method === 'cash' || d.pay_method === 'e_transfer' ? `${methodLabel(d.pay_method)}, at pickup`
    : d.pay_method === 'none' ? 'not taken (waived)'
    : `taken at pickup on the card on file: a hold for rentals of ${d.card_hold_days ?? 7} days or less, otherwise charged and refunded`;
  const state = d.status === 'held' ? 'held' : d.status === 'captured' ? 'received' : d.status === 'settled' ? 'settled' : d.status === 'failed' ? 'declined' : null;
  const after = [d.applied_cents ? `${money(d.applied_cents, { cents: true })} applied to charges` : '', d.released_cents ? `${money(d.released_cents, { cents: true })} returned` : '',
    d.held_back_cents ? `${money(d.held_back_cents, { cents: true })} held back` : ''].filter(Boolean).join(', ');
  return `${money(d.amount_cents, { cents: true })}, ${how}${state ? ` (${state}${d.taken_at ? ` ${d.taken_at.slice(0, 10)}` : ''})` : ''}${after ? `; ${after}` : ''}`;
}

/** How the rental was paid: each payment received (refunds as negatives), or the way agreed when nothing is in yet. */
export function paidText(x: AgreementExtra, card: { brand: string; last4: string } | null): string {
  const pays = x.payments.filter((p) => p.purpose !== 'deposit');
  if (pays.length) return pays.map((p) => `${money(p.amount_cents, { cents: true })} by ${p.method === 'card' && p.card_last4 ? `${(p.card_brand ?? 'card').toUpperCase()} ending ${p.card_last4}` : methodLabel(p.method)} on ${p.at.slice(0, 10)}${p.reference ? ` (ref. ${p.reference})` : ''}`).join('; ');
  const m = x.booking.rental_pay_method;
  if (!m || m === 'card') return card ? `To be charged to ${card.brand.toUpperCase()} ending ${card.last4}` : 'By card, at booking';
  return `By ${methodLabel(m)}`;
}

/** The lines of a stage, and their sums. */
export const stageLines = (x: AgreementExtra, stages: string[]) => x.lines.filter((l) => stages.includes(l.stage));
export const sum = (ls: Line[], k: 'amount_cents' | 'hst_cents' = 'amount_cents') => ls.reduce((s, l) => s + (l[k] ?? 0), 0);

// ---------------------------------------------------------------- the key terms a signer initials (0143)
export type ClauseCode = 'damage' | 'charges' | 'fees' | 'coverage' | 'cancellation';
export interface Clause { code: ClauseCode; title: string; text: string }
export interface ClauseFacts {
  deductible_cents: number | null; deposit: string; card: string | null; km_per_day: number | null; km_total: number | null; overage_cents_per_km: number | null;
  grace_minutes: number | null; late_fee_cents: number | null; coverage: string; booking_type: string; difference?: string | null;
}
export function clauses(f: ClauseFacts): Clause[] {
  const kmText = f.km_per_day === null ? 'unlimited kilometres' : `${f.km_total ?? 0} km included (${f.km_per_day} km a day), then ${money(f.overage_cents_per_km, { cents: true })} for each kilometre over`;
  return [
    { code: 'damage', title: 'Damage and the deductible', text: `I am responsible for loss of or damage to the car during the rental, up to the deductible of ${money(f.deductible_cents)} where a coverage option applies, and in full where it does not (Part 2).` },
    { code: 'charges', title: 'The deposit and later charges', text: `I authorize the deposit (${f.deposit}) and later charges under this agreement (tolls, tickets, fuel, kilometres, late return, cleaning, damage up to the deductible) on ${f.card ?? 'the card on file'}${f.difference ? `, and ${f.difference}` : ''}.` },
    { code: 'fees', title: 'Fuel, kilometres and late returns', text: `The car comes back with the same fuel or charge, else refuelling is charged; ${kmText}; a return later than ${f.grace_minutes ?? 0} minutes after the due-back time is charged each extra day or part day${f.late_fee_cents ? ` plus the late fee of ${money(f.late_fee_cents)}` : ''}.` },
    { code: 'coverage', title: 'My coverage choice', text: `My coverage for the car: ${f.coverage}. I have read what it covers and what it does not.` },
    { code: 'cancellation', title: 'Cancellation', text: f.booking_type === 'non_refundable' ? 'My booking is non-refundable (10% discount): it is not refunded if I cancel (Part 2).' : 'The cancellation policy of Part 2 applies to my booking.' }
  ];
}
export const CONSENTS = {
  esign: 'I agree to sign this agreement electronically. My electronic signature and initials are as binding as my handwritten ones (Ontario Electronic Commerce Act, 2000).',
  erecords: 'I agree to receive this agreement, its versions and the records of my rental electronically, by email and in my booking, and I can download and keep them.',
  card: 'I authorize CarmaCars to charge the card on file for the deposit and the later charges set out in this agreement, as they arise.'
} as const;
export type ConsentCode = keyof typeof CONSENTS;
