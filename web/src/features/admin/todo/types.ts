import type { ReviewCoverage } from '@/features/coverage/types';

// What app.todo_prompts returns (migration 0078): one prompt per piece of work. title says what to do, why says why,
// both one line; the rest is what the prompt's pop-up needs, pre-filled.
export type PromptKind = 'insurer' | 'insurer_bulk' | 'publish' | 'documents' | 'chat' | 'requests' | 'changes' | 'applications' | 'invoice_payment'
  | 'invoice_draft' | 'paper' | 'forms' | 'plates' | 'photos' | 'task' | 'first_last_paid' | 'terms' | 'trim' | 'specs';

export interface Prompt {
  key: string; kind: PromptKind; priority: 1 | 2 | 3; title: string; why: string | null; since: string | null;
  vehicle_id?: string; name?: string; plate?: string | null; booking_number?: string | null; onboarding_status?: string | null;
  cars?: Array<{ vehicle_id: string; name: string; plate?: string | null; voided_cents?: number | null; signed?: boolean; terms?: Terms }>;
  drafts?: Array<{ invoice_id: string; invoice_number: string; total_cents: number }>;
  grid?: Terms;
  suggested?: { daily_cents: number; source: string; text: string } | null;
  rates?: { daily: number | null; weekend: number | null; weekly: number | null; monthly: number | null } | null;
  chat_id?: string; request_id?: string; application_id?: string;
  invoice_id?: string; invoice_number?: string; balance_cents?: number; owner?: string; owner_id?: string | null;
  docs?: Array<{ code: string; label: string; doc_type?: string; target_id: string; vehicle_name?: string | null }>;
  template_id?: string; form_code?: string;
  /** 0094: the trims to choose from (trim); the gearbox and seats on the listing, and whether the seats are a body default (specs) */
  candidates?: string[]; transmission?: string | null; seats?: number | null; seats_default?: boolean;
  task_id?: string; task_type?: string; queue?: string; due_at?: string | null; related_table?: string | null; related_id?: string | null; from_queue?: boolean;
}

export interface Todo {
  items: Array<{ key: string; label: string; button: string; href: string; count: number }>;
  prompts?: Prompt[];
  staffed?: Record<'cs' | 'sales' | 'finance' | 'fleet', boolean>;
  pickups: Array<{ booking_number: string; at: string; vehicle: string; renter: string; ready: boolean }>;
  returns: Array<{ booking_number: string; at: string; vehicle: string; renter: string; late: boolean }>;
  /** 0093: chauffeur bookings confirmed for today */
  chauffeur_today?: Array<{ reference: string; start_time: string; vehicle: string; name: string; hours: number }>;
  late: number;
}

export interface DocUpload { id: string; kind: string; driver_id: string | null; status: string; uploaded_at: string; reject_reason: string | null; mime_type: string | null;
  bucket?: string | null; path?: string | null; url?: string | null }
type ReviewProof = NonNullable<ReviewCoverage['proof']>;
export interface DocReview {
  booking_id: string; booking_number: string; status: string; pickup_at: string; return_at: string; coverage_option: number | null; renter_name: string | null; vehicle_name: string | null;
  readiness: { all_drivers_verified?: boolean; coverage_confirmed?: boolean; identity_and_coverage_confirmed?: boolean };
  /** 0169: Sales see the licence front, back and selfie only (no coverage) */
  licence_only?: boolean;
  drivers: Array<{ driver_id: string; full_name: string; role: string; date_of_birth: string | null; licence_number: string | null; licence_class: string | null; licence_expiry: string | null; verified_on: string | null }>;
  uploads: DocUpload[];
  coverage: (Omit<ReviewCoverage, 'proof'> & { proof: (Omit<ReviewProof, 'pages'> & { pages: Array<ReviewProof['pages'][number] & { url?: string | null }> }) | null }) | null;
  waiting: number;
}

/** An owner's or a car's terms as owner_terms_resolve gives them (numbers as text from the database). */
export interface Terms { revenue_share_bps: string | number | null; insurance_fee_cents: string | number | null; tracker_fee_cents: string | number | null; install_fee_cents: string | number | null; first_last_cents: string | number | null }
