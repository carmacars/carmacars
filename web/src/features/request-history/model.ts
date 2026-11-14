// r35a (migrations 1300 to 1305): the shapes of the request history read (ops_read request_history) and the words used for
// the owner's own trip and an instant booking, the same on every staff screen.
export const OWNER_TRIP = "Owner's own trip ($0)";
export const INSTANT_REPEAT = 'Instant (repeat renter)';

export interface PriceLine { charge_type: string; description: string | null; amount_cents: number; hst_cents: number }
export interface Price { rental_charge_cents: number; discount_cents: number; subtotal_cents: number; hst_cents: number; total_cents: number; renter_due_cents: number;
  deposit_cents: number; rate_applied: string | null; promo_code: string | null; km_allowance_per_day: number | null; lines: PriceLine[] }
export interface Original { source: 'request' | 'backfill'; captured_at: string; requested_at: string | null; vehicle_id: string | null; vehicle_name: string | null;
  pickup_at: string | null; return_at: string | null; billable_days: number | null; pickup_place: string | null; return_place: string | null; booking_type: string | null;
  coverage_option: number | null; coverage_label: string | null; note: string | null; addons: Array<{ name: string; quantity: number; hours: number | null; status: string }>;
  price: Price | null; drivers: number; extras: { winter_tire?: boolean; baby_seats?: number } | null; promo_code: string | null; heard_about: string | null }
export interface OfferVersion { version: number; status: string; current: boolean; sent_at: string; sent_by_name: string; expires_at: string; responded_at: string | null;
  response_note: string | null; message: string | null; vehicle_id: string; vehicle_name: string | null; pickup_at: string; return_at: string; billable_days: number;
  rental_charge_cents: number; discount_cents: number; deposit_cents: number; subtotal_cents: number; hst_cents: number; total_cents: number;
  insurer_share_cents: number; renter_due_cents: number; rate_applied: string | null; km_allowance_per_day: number | null; promo_code: string | null; lines: PriceLine[] }
export type ProofState = 'not_needed' | 'no_choice' | 'missing' | 'submitted' | 'confirmed' | 'rejected';
export interface CoverageCard { option: number | null; short: string | null; label: string; requested_option: number | null; confirmed_at: string | null; proof: ProofState;
  proof_words: string; detail: string | null; rejection_reason: string | null }
export interface History { booking_id: string; booking_number: string; status: string; booking_type: string; owner_trip: boolean; instant_book: boolean;
  current_offer_version: number | null; made_by_staff: boolean; original: Original | null; offers: OfferVersion[]; coverage: CoverageCard | null; may_revert: boolean }
/** The changes ops_read offer_revert answers: loaded into the review screen as a new offer to send. */
export interface Revert { version: number; sent_at: string; total_cents: number; changes: Record<string, unknown>; lines: Record<string, number>; promo_code: string; message: string }

export const OFFER_STATUS: Record<string, string> = { sent: 'Out with the renter', approved: 'Accepted', superseded: 'Replaced', expired: 'Expired', withdrawn: 'Withdrawn', declined: 'Declined' };
export const PROOF_TONE: Record<ProofState, 'ok' | 'amber' | 'red' | 'quiet'> = { not_needed: 'ok', confirmed: 'ok', submitted: 'amber', missing: 'red', rejected: 'red', no_choice: 'red' };

/** A line's words: its description, else its type in words. */
export const lineWords = (l: PriceLine) => l.description || l.charge_type.replace(/_/g, ' ');

/** What changed between two price lists, in words ("Total $480.00 to $430.00"), for the history's rows. */
export function priceChange(a: { total_cents: number } | null, b: { total_cents: number }, fmt: (c: number) => string): string | null {
  if (!a || a.total_cents === b.total_cents) return null;
  return `Total ${fmt(a.total_cents)} to ${fmt(b.total_cents)}`;
}

/** The link that opens the review with an old version loaded (the booking page reads ?revert=). */
export const revertHref = (base: string, version: number) => `${base}?tab=overview&revert=${version}#booking-review`;

// r45 (2861): the versions of a confirmed booking (ops_read booking_versions) and Restore this version
export interface BookingVersion { no: number; at: string; by: string | null; reason: string | null; kind: 'start' | 'change' | 'restore'; restored: number | null; current: boolean;
  pickup_at: string; return_at: string; vehicle_id: string; vehicle: string | null; billable_days: number; rental_charge_cents: number; total_cents: number; lines: Record<string, number> | null }
export interface BookingVersions { booking_number: string; status: string; refusal: string | null; may_restore: boolean; versions: BookingVersion[] }
export interface RestorePreview { ok: boolean; problem: string | null; changed: boolean; preview: boolean; version: number; message?: string; fees_kept?: boolean;
  total_before_cents?: number; total_after_cents?: number | null; open_before_cents?: number; open_after_cents?: number | null; unmatched?: string[];
  before?: { pickup_at: string; return_at: string; vehicle: string | null; billable_days: number; rental_charge_cents: number };
  after?: { pickup_at: string; return_at: string; vehicle: string | null; billable_days: number; rental_charge_cents: number } | null }

/** A version's label: "Version 1, as confirmed", "Version 4 (current)", "Version 5, restored version 1". */
export function versionLabel(v: Pick<BookingVersion, 'no' | 'kind' | 'restored' | 'current'>): string {
  const what = v.kind === 'start' ? ', before the first change' : v.kind === 'restore' && v.restored ? `, version ${v.restored} restored` : '';
  return `Version ${v.no}${what}${v.current ? ' (current)' : ''}`;
}

/** What the renter's balance does after a restore, in words: owes more, gets a credit, or no change. */
export function balanceWords(before: number | null | undefined, after: number | null | undefined, fmt: (c: number) => string): string {
  if (before === null || before === undefined || after === null || after === undefined) return '';
  const diff = after - before;
  if (diff === 0) return 'The balance does not change.';
  return diff > 0 ? `The renter owes ${fmt(diff)} more (a balance to collect, as with any change).` : `The renter is owed ${fmt(-diff)} (a credit or refund to settle, as with any change). No payment is touched.`;
}
