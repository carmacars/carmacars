// Shapes of public.my_booking(), my_bookings(), my_profile() and friends (migration 0028).
export type BookingStatus = 'requested' | 'offered' | 'pending_payment' | 'confirmed' | 'on_rent' | 'returned' | 'closed' | 'cancelled' | 'expired' | 'declined';

export interface OfferLine { charge_type: string; description?: string; label?: string; amount_cents: number; hst_cents?: number; quantity?: number }
export interface Offer {
  version: number; status: string; sent_at: string | null; expires_at: string | null; message: string | null; vehicle_id: string;
  pickup_at: string; return_at: string; billable_days: number; rental_charge_cents: number; discount_cents: number; deposit_cents: number;
  subtotal_cents: number; hst_cents: number; total_cents: number; insurer_share_cents: number; renter_due_cents: number;
  terms: Record<string, unknown> | null; line_items: OfferLine[] | null; responded_at: string | null; response_note: string | null;
  vehicle: { slug: string; year: number; make: string; model: string } | null;
}
export interface Line { id: string; charge_type: string; description: string; quantity: number; unit_amount_cents: number; amount_cents: number; hst_cents: number; stage: string; payment_id: string | null; created_at: string }
export interface Payment { id: string; purpose: string; kind: string; amount_cents: number; status: string; card_brand: string | null; card_last4: string | null; processed_at: string | null; created_at: string }
export interface BookingDriver { id: string; driver_id: string; role: 'renter' | 'additional'; full_name: string; licence_class: string | null; licence_issuer: string | null; licence_expiry: string | null; has_licence_number: boolean; age_band: string | null; identity_verified_on: string | null; accepted_at: string | null }
export interface Signer { id: string; role: 'renter' | 'additional_driver' | 'carmacars'; name: string; booking_driver_id: string | null; signed_at: string | null; required_before_payment: boolean }
export interface Agreement { id: string; status: 'open' | 'signed' | 'completed'; agreement_number: string; offer_version: number | null; template_version: string; document_id: string; document_sha256: string; signature_request_id: string; renter_signed_at: string | null; countersigner_name: string | null; opened_at: string; completed_at: string | null; signed_document_id: string | null; signers: Signer[] }
export interface InfoRequest { id: string; question: string; asked_at: string; reply_by: string | null; status: string; reply: string | null; replied_at: string | null }
export interface Upload { id: string; driver_id: string | null; kind: 'licence_front' | 'licence_back' | 'selfie' | 'coverage_proof'; status: 'submitted' | 'approved' | 'rejected' | 'replaced'; reject_reason: string | null; document_id: string; uploaded_at: string }
export interface Doc { id: string; kind: string; title: string | null; mime_type: string | null; created_at: string; purge_after: string | null; purged: boolean; booking_number?: string | null }
export interface Extension { id: string; seq: number; status: string; requested_at: string; previous_return_at: string; new_return_at: string; new_days: number; total_cents: number | null; hst_cents: number | null; paid_at: string | null; decline_reason: string | null; note: string | null }
export interface ChangeRequest { id: string; status: string; note: string | null; changes: Record<string, unknown> | null; before: Record<string, unknown> | null; after: Record<string, unknown> | null; total_difference_cents: number | null; decline_reason: string | null; created_at: string }
export interface Readiness { drivers?: Array<{ name?: string; verified?: boolean }>; coverage_confirmed?: boolean; missing: string[]; ready_for_handover: boolean; [k: string]: unknown }

export interface BookingSummary {
  id: string; booking_number: string; status: BookingStatus; booking_type: string; vehicle_id: string; vehicle_year: number; vehicle_make: string; vehicle_model: string; car_code?: string | null;
  vehicle_colour: string | null; slug: string | null; pickup_at: string; return_at: string; pickup_place: string | null; return_place: string | null;
  pickup_method: string; return_method: string; billable_days: number; offer_expires_at: string | null; current_offer_version: number | null;
  offer_approved_version: number | null; total_due_at_booking_cents: number; renter_due_at_booking_cents: number; deposit_cents: number;
  hst_at_booking_cents: number; subtotal_at_booking_cents: number; insurer_pays_cents: number; coverage_option: number | null;
  coverage_confirmed_at: string | null; confirmed_at: string | null; handed_over_at: string | null; checked_in_at: string | null;
  request_note: string | null; km_allowance_total: number | null; overage_cents_per_km: number | null; deductible_cents: number | null;
  agreement_number: string | null; requested_at: string | null; booked_at: string | null;
}

export interface MyBooking extends BookingSummary {
  request: Record<string, unknown> & { vehicle?: { year: number; make: string; model: string } | null; pickup_at?: string; return_at?: string; pickup_place?: string | null; return_place?: string | null; booking_type?: string; coverage_option?: number | null; pickup_method?: string; return_method?: string };
  offers: Offer[]; lines: Line[]; payments: Payment[]; drivers: BookingDriver[]; agreement: Agreement | null; info_requests: InfoRequest[];
  uploads: Upload[]; documents: Doc[]; change_requests: ChangeRequest[]; extensions: Extension[];
  cancellation: { tier: string | null; refund_cents: number | null; received_at: string; refund_bps: number | null } | null;
  refunds: Array<{ id: string; amount_cents: number; status: string; created_at: string }>;
  statements: Array<Record<string, unknown>>;
  readiness: Readiness | null;
  /** A rental staff added by hand (0046), live: confirmed, or on trip since it was added while already underway (0074). */
  added_by_staff?: boolean; added_live?: boolean; added_mode?: string | null;
  /** A rental added while underway with a payment link, waiting for the online payment after signing (0074). */
  link_due?: boolean;
  /** Confirmed on a payment received another way before the renter signed (0185): sign with no payment step after. */
  paid_unsigned?: boolean;
}

/** A live rental staff added by hand: the renter signs it with no payment step before it (0046, 0074). */
export function addedLive(b: { added_by_staff?: boolean; added_live?: boolean; status: string }): boolean {
  return b.added_live ?? (!!b.added_by_staff && b.status === 'confirmed');
}

export interface Profile {
  user: { id: string; email: string; phone: string | null; full_name: string | null; marketing_opt_in: boolean; marketing_opt_in_at: string | null } | null;
  renter: { id: string; legal_name: string | null; mobile: string | null; email: string | null; address_line1: string | null; address_line2: string | null; city: string | null; province: string | null; postal_code: string | null; country: string | null; identity_status: string } | null;
  drivers: Array<{ id: string; full_name: string; is_account_holder: boolean; licence_class: string | null; licence_issuer: string | null; licence_expiry: string | null; identity_status: string }>;
  cards: Array<{ id: string; brand: string; last4: string; exp_month: number; exp_year: number; cardholder_name: string | null }>;
}

export interface Notice { id: string; code: string; title: string; body: string | null; url: string | null; created_at: string; read_at: string | null }
export interface NoticePref { code: string; subject: string; category: string; user_can_mute: boolean; email_enabled: boolean; in_app_enabled: boolean }
