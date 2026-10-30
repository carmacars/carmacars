import type { DocReview, DocUpload } from '@/features/admin/todo/types';

// One field job as app.field_read('job') returns it (migration 0031).
export interface FieldDamage { label: string; location: string; description: string; kind?: string | null; size_cm?: number | null; position?: { x: number; y: number } | null; is_new?: boolean }
export interface FieldJob {
  job: { id: string; kind: string; status: string; scheduled_at: string; place: string | null; instructions: string | null; booking_id: string | null; vehicle_id: string; acknowledged_at: string | null; started_at: string | null; completed_at: string | null };
  report_kind: 'pickup' | 'return' | 'ready' | null;
  /** 0195: a pickup or return recorded with the details later: the photos, readings and staff signature only */
  details_later?: boolean;
  vehicle: { id: string; name: string; plate: string | null; colour: string | null; class: string; odometer_km: number | null };
  booking: null | {
    id: string; booking_number: string; status: string; pickup_at: string; return_at: string; unattended: boolean; km_allowance_total: number | null; odometer_out_km: number | null; fuel_out_pct: number | null; booking_type: string;
    renter: { name: string; mobile: string | null } | null;
    drivers: Array<{ name: string; role: string; licence_number: string | null; licence_class: string | null; licence_expiry: string | null; verified: boolean; accepted: boolean }>;
    card: { brand: string | null; last4: string | null } | null; extras: string[];
    /** 0066: the add-ons to put in the car, and whether fuel is prepaid (no fuel charge at the return) */
    addons?: Array<{ name: string; quantity: number; hours: number | null; status: string; handover_note: string | null; prepaid_fuel: boolean }>; prepaid_fuel?: boolean;
  };
  ready: null | { identity: boolean; coverage: boolean; drivers_accepted: boolean; calendar: boolean; agreement: boolean; deposit: 'taken' | 'waived' | 'declined' | 'not_taken' | 'none';
    /** False while a rental staff added by hand waits for the renter's signature (0051): the car is not released. */
    signed?: boolean;
    /** 0071: the coverage in words */
    coverage_label?: string | null };
  tracker: { installed: boolean; reported_at: string | null; reporting: boolean; override?: TrackerOverride | null };
  /** What the check-out screens need to resolve the ready check on the spot (0151). */
  resolve?: Resolve;
  shots: Array<{ seq: number; shot: string; guide: string | null }>;
  report: null | { id: string; odometer_km: number | null; fuel_pct: number | null; keys_count: number | null; cleanliness: string | null; completed_at: string | null;
    photos: Array<{ seq: number; shot: string; storage_path: string }>; damages: FieldDamage[]; problems: string[] };
  pickup: null | { odometer_km: number | null; fuel_pct: number | null; keys_count: number | null; damages: FieldDamage[] };
  baseline_damages: FieldDamage[];
  move: null | { id: string; started_at: string };
  now: string;
  /** The checklist of a job of any other kind, or a re-shoot (migration 0033). */
  checklist?: JobChecklistData | null;
}
export interface Step { key: string; type: 'tick' | 'rules' | 'choice' | 'text' | 'number' | 'serial' | 'photos' | 'shots' | 'listing' | 'reshoot'; label: string; help?: string; text?: string; required?: boolean; min?: number; stop?: boolean; options?: Array<[string, string]> }
export interface Answer { v?: string; note?: string; photos?: string[] }
export interface JobChecklistData { steps: Step[]; answers: Record<string, Answer>; missing: string[];
  listing: { intake_id: string; state: string; submitted_at: string | null } | null;
  reshoot: { report_id: string; kind: string; shots: Array<{ seq: number; shot: string; guide: string | null; done: boolean }> } | null }
export interface FieldList {
  today: FieldCard[]; tomorrow: FieldCard[]; name: string | null;
  moves: Array<{ id: string; vehicle_id: string; vehicle_name: string; purpose: string; started_at: string; from_place: string | null }>;
  vehicles: Array<{ id: string; name: string }>;
}
export interface FieldCard { field_job_id: string; kind: string; status: string; scheduled_at: string; place: string | null; vehicle_id: string; vehicle_label: string; plate: string | null; booking_id: string | null; booking_number: string | null; renter_first_name: string | null; acknowledged_at: string | null; started_at: string | null; completed_at: string | null }

// 0151: the ready check resolved on the spot
export interface TrackerOverride { reason: string; at: string; by: string | null }
export interface LicenceState { licence_front?: string | null; licence_back?: string | null; selfie?: string | null; expiry: string | null; expiry_ok: boolean; missing: string[]; complete: boolean; verified: boolean }
export interface Resolve {
  drivers: Array<{ driver_id: string; name: string; role: string; verified: boolean; licence: LicenceState }>;
  deposit_cents: number; deposit_methods: Array<'e_transfer' | 'cash'>; e_transfer_email: string | null; selfie_required: boolean;
  awaiting_signature: boolean; tracker_override_allowed: boolean; tracker_override: TrackerOverride | null;
  resolutions: Array<{ kind: string; at: string; reason: string | null; by: string | null }>;
}

// 0162: the licence review of field staff. A card of "Licences to check" (field_read('licences')) and one booking's licence
// images (field_read('licence_review'), with one-minute private links in each upload's url).
export interface LicenceCard { field_job_id: string; kind: string; status: string; scheduled_at: string; place: string | null; vehicle_id: string; vehicle_label: string; plate: string | null;
  booking_id: string; booking_number: string; renter_first_name: string | null; waiting: number }
export interface LicenceReviewData { job_id: string; booking_id: string; booking_number: string; status: string; pickup_at: string; return_at: string; renter_name: string | null; vehicle_name: string | null;
  readiness: { all_drivers_verified?: boolean }; drivers: DocReview['drivers']; uploads: DocUpload[]; waiting: number }
