// Shapes of the owner portal reads (migration 0029). Money is integer cents from the database.
export interface ChecklistItem { code: string; label: string; status: 'done' | 'open' | 'not_applicable'; waits_on: string | null; next_action: string | null }
export interface OwnerVehicle {
  vehicle_id: string; name: string; plate: string | null; status: string; management_mode: string; onboarding_status: string | null;
  enrollment_date: string | null; exit_date: string | null; insurance_fee_cents: number | null; tracker_fee_cents: number | null;
  revenue_share_bps: number | null; listing_status: string | null; listing_path: string | null; estimate_cents: number | null;
  government_forms: string[] | null; next: { item: string; waits_on: string; action: string | null } | null; checklist: ChecklistItem[] | null;
}
export interface OwnerInvoiceRow {
  id: string; invoice_number: string; vehicle_id: string; vehicle_name: string; kind: 'upfront' | 'monthly' | 'adjustment' | 'tracker_install'; period_month: string | null;
  billing_date: string; retry_on: string | null; status: string; fees_cents: number; hst_cents: number; late_fee_cents: number; total_cents: number;
  balance_cents: number; paid_at: string | null; payment_method: string; pending: boolean; payable: boolean;
}
export interface OwnerInvoice extends OwnerInvoiceRow {
  owner_id: string; plate: string | null; days_billed: number | null; days_in_month: number | null; paid_cents: number; deducted_cents: number; issued_at: string | null;
  owner_name: string; owner_email: string | null; company_hst_number: string | null;
  lines: Array<{ kind: string; description: string | null; amount_cents: number; hst_cents: number }>;
  payments: Array<{ id: string; method: string; status: string; amount_cents: number; card_brand: string | null; card_last4: string | null; decline: string | null; created_at: string; processed_at: string | null; reference: string | null }>;
  saved_methods: Array<{ kind: string; brand_or_bank: string | null; last4: string | null; is_default: boolean }>;
}
export interface OwnerProfile {
  id: string; owner_type: 'individual' | 'corporation'; legal_name: string; first_name: string; corporation_name: string | null; corporation_number: string | null;
  email: string | null; phone: string | null; hst_number: string | null; address_line1: string | null; address_line2: string | null; city: string | null;
  province: string | null; postal_code: string | null; country: string | null; signing_officer_name: string | null; signing_officer_title: string | null;
  balance_carried_forward_cents: number; missing: string[];
}
export interface OwnerHome {
  owner: OwnerProfile;
  vehicles: OwnerVehicle[];
  invoices: OwnerInvoiceRow[];
  statements: Array<{ id: string; statement_number: string; statement_month: string; payout_date: string; status: string; payout_cents: number }>;
  payouts: Array<{ id: string; kind: string; amount_cents: number; method: string; scheduled_for: string; status: string }>;
  signing: { needed: boolean; enrollment: string | null; title_holding: string | null; unsigned_schedules: number; signed_schedules: number };
  payment_methods: Array<{ id: string; kind: string; status: string; brand_or_bank: string | null; last4: string | null; is_default: boolean; authorized_at: string | null }>;
  payout_accounts: Array<{ id: string; method: string; account_last4: string | null; institution_no: string | null; e_transfer_email: string | null; is_current: boolean; verified_at: string | null; submitted_at: string }>;
  exits: Array<{ id: string; vehicle_id: string; status: string; exit_date: string; notice_ends_on: string; retransfer_fees_paid_by: string }>;
  next_payout_date: string; next_billing_date: string;
  trackers_available: boolean; tracker_pending: string[];
}
export interface OwnerBooking {
  booking_id: string; booking_number: string; booking_type: string; status: string; vehicle_id: string; vehicle_name: string;
  pickup_at: string; return_at: string; rental_charge_cents: number; renter_name: string | null; renter_mobile: string | null;
}
export interface StatementLine {
  id: string; line_type: string; description?: string; booking_number?: string; invoice_number?: string; from_vehicle_name?: string;
  starts_on?: string; ends_on?: string; rental_charge_cents?: number; mileage_overage_cents?: number; refunds_cents?: number; chargebacks_cents?: number;
  kickback_cents?: number; owner_revenue_cents?: number; revenue_share_cents?: number; turo_gross_cents?: number; turo_fees_cents?: number;
  fee_cents?: number; late_fee_cents?: number; amount_cents: number;
}
export interface OwnerStatement {
  statement: { id: string; statement_number: string; statement_month: string; payout_date: string; status: string; is_final: boolean;
    owner_revenue_cents: number; revenue_share_cents: number; net_earnings_cents: number; deductions_cents: number; vehicles_payable_cents: number;
    arrears_moved_cents: number; kickbacks_earned_cents: number; hst_on_payout_cents: number; balance_brought_forward_cents: number;
    payout_cents: number; balance_carried_forward_cents: number };
  vehicles: Array<{ vehicle_id: string; name: string; plate: string | null; management_mode: string; totals: Record<string, number>; lines: StatementLine[] }>;
  owner_lines: StatementLine[];
  payout: { amount_cents: number; status: string; method: string; paid_at: string | null; reference: string | null; scheduled_for: string } | null;
}
export interface OwnerDoc { id: string; kind: string; title: string | null; vehicle_id: string | null; created_at: string }
export interface OwnerForm { id: string; form_code: string; title: string | null; vehicle_id: string; vehicle_name: string; mode: string; status: string; missing: string[]; data_sheet: Array<{ label: string; value: string | null; section?: string }>; has_pdf: boolean; generated_at: string }

export const INVOICE_STATUS: Record<string, { label: string; badge: string }> = {
  issued: { label: 'Due', badge: 'badge--outline' },
  processing: { label: 'Processing', badge: 'badge--grey' },
  retry_processing: { label: 'Retrying', badge: 'badge--grey' },
  paid: { label: 'Paid', badge: '' },
  failed: { label: 'Failed, retry on the 18th', badge: 'badge--red' },
  in_arrears: { label: 'In arrears', badge: 'badge--red' },
  partially_deducted: { label: 'Part deducted from payout', badge: 'badge--outline' },
  deducted: { label: 'Deducted from payout', badge: '' },
  void: { label: 'Void', badge: '' },
  draft: { label: 'Draft', badge: '' }
};
export const invoiceStatus = (i: Pick<OwnerInvoiceRow, 'status' | 'pending'>) => (i.pending && i.status !== 'paid' ? { label: 'Payment processing', badge: 'badge--grey' } : INVOICE_STATUS[i.status] ?? { label: i.status, badge: '' });

export const invoiceTitle = (i: { kind: string; period_month: string | null }, month: (iso: string | null) => string) =>
  i.kind === 'upfront' ? 'First and last month\'s insurance' : i.kind === 'tracker_install' ? 'Tracker install' : i.kind === 'adjustment' ? 'Adjustment' : `Fees for ${month(i.period_month)}`;
export const TRACKER_LATER = 'A Tracker Install Fee applies when trackers become available. We bill it then, on its own invoice.';
export const ONBOARDING_STATUS: Record<string, string> = {
  intake: 'Application with our team', declined: 'Declined', withdrawn: 'Withdrawn', terms_set: 'Terms ready to sign',
  documents_sent: 'Agreements to sign', documents_signed: 'Agreements signed', upfront_paid: 'Upfront invoice paid',
  registry_booked: 'Registry visit booked', registered: 'Registered', tracker_installed: 'Tracker installed',
  on_fleet_policy: 'On the fleet policy', enrolled: 'Enrolled'
};
export const MODE_LABEL: Record<string, string> = { managed: 'Managed', self_managed: 'Self-Managed', turo_only: 'Turo-Only' };
export const METHOD_LABEL: Record<string, string> = {
  lease_existing_corporation: 'Lease, existing corporation', lease_new_owner_corporation: 'Lease, new Owner Corporation',
  co_registrant: 'Co-Registrant', transfer: 'Transfer', none: 'None (Turo-Only)'
};
export const PAY_METHOD_LABEL: Record<string, string> = { card: 'Card', pre_authorized_debit: 'Pre-authorized debit', e_transfer: 'e-Transfer', cheque: 'Cheque', bank_transfer: 'Bank transfer' };
