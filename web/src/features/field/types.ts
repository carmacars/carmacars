// One field job as app.field_read('job') returns it (migration 0031).
export interface FieldDamage { label: string; location: string; description: string; kind?: string | null; size_cm?: number | null; position?: { x: number; y: number } | null; is_new?: boolean }
export interface FieldJob {
  job: { id: string; kind: string; status: string; scheduled_at: string; place: string | null; instructions: string | null; booking_id: string | null; vehicle_id: string; acknowledged_at: string | null; started_at: string | null; completed_at: string | null };
  report_kind: 'pickup' | 'return' | 'ready' | null;
  vehicle: { id: string; name: string; plate: string | null; colour: string | null; class: string; odometer_km: number | null };
  booking: null | {
    id: string; booking_number: string; status: string; pickup_at: string; return_at: string; unattended: boolean; km_allowance_total: number | null; odometer_out_km: number | null; fuel_out_pct: number | null; booking_type: string;
    renter: { name: string; mobile: string | null } | null;
    drivers: Array<{ name: string; role: string; licence_number: string | null; licence_class: string | null; licence_expiry: string | null; verified: boolean; accepted: boolean }>;
    card: { brand: string | null; last4: string | null } | null; extras: string[];
  };
  ready: null | { identity: boolean; coverage: boolean; drivers_accepted: boolean; calendar: boolean; agreement: boolean; deposit: 'taken' | 'waived' | 'declined' | 'not_taken' | 'none' };
  tracker: { installed: boolean; reported_at: string | null; reporting: boolean };
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
