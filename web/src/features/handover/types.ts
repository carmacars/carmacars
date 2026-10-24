// What the database returns for the check-out, check-in and signing screens (migration 0130).
export interface LicenceStatus { licence_front?: string | null; licence_back?: string | null; selfie?: string | null; expiry: string | null; expiry_ok: boolean; missing: string[]; complete: boolean; verified?: boolean }
export interface Signer { id: string; role: 'renter' | 'additional_driver'; name: string; signed_at: string | null; driver_id: string | null; in_person: boolean | null; licence: LicenceStatus }
export interface SigningState {
  booking_id: string; booking_number: string; status: string; renter_user_id: string | null; renter_mobile: string | null; renter_email: string | null; added: boolean; link_due: boolean;
  agreement: { id: string; status: string; document_id: string; document_sha256: string; agreement_number: string | null } | null;
  companion: { status: string; document_id: string; document_sha256: string } | null;
  signers: Signer[];
}
export interface ReportPhoto { seq: number; shot: string; bucket: string; path: string; taken_at: string | null; latitude: number | null; longitude: number | null; damage_label: string | null }
export interface ReportDamage { label: string; location: string | null; description: string | null; kind: string | null; size_cm: number | null; is_new: boolean; found_later: boolean | null; status_vs_pickup: string | null }
export interface ConditionSide {
  id: string; kind: 'pickup' | 'return' | 'swap_out' | 'swap_in'; performed_at: string | null; completed_at: string | null; performed_by_name: string | null;
  odometer_km: number | null; fuel_pct: number | null; keys_count: number | null; cleanliness: string | null; notes: string | null; unattended: boolean | null;
  renter_signed_at: string | null; staff_signed_at: string | null; renter_declined_to_sign: boolean | null; photos: ReportPhoto[]; damages: ReportDamage[];
}
export interface HandoverReportData {
  booking_id: string; booking_number: string; status: string; vehicle: string; plate: string | null; pickup_at: string; return_at: string;
  handed_over_at: string | null; checked_in_at: string | null; minutes_late: number; overdue: boolean; grace_minutes: number | null; extra_days: number | null;
  km_out: number | null; km_in: number | null; km_driven: number | null; km_allowance: number | null; km_over: number; overage_cents_per_km: number | null;
  fuel_out_pct: number | null; fuel_in_pct: number | null; fuel_short_pct: number; electric: boolean | null;
  reports: ConditionSide[];
  charges: Array<{ key: string; label: string; amount_cents: number; hst_cents: number; on_statement: boolean }>;
  waivers?: Array<{ key: string; reason: string; by: string | null; at: string }>;
}
