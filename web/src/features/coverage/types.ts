import type { Funding } from './card';

// What app.renter_coverage and app.coverage_review_facts return (the coverage proof migration).
export interface CardCheck {
  eligible: boolean; problem: 'no_card' | 'not_credit' | 'name_mismatch' | null; message: string | null;
  payment_method_id: string | null; brand: string | null; last4: string | null; funding: Funding | null; country: string | null;
  cardholder_name: string | null; renter_name?: string | null; name_matches: boolean; vehicle_class: string | null; rental_days: number;
}
/** app.card_product_check (1400): the card the renter picked against this car and rental. */
export interface CardProductCheck {
  result: 'covered' | 'not_covered' | 'review'; reasons: Array<{ code: string; text: string; types?: string[] }>; message: string;
  card_id: string | null; card_label: string | null; network: string | null; cdw_included: 'yes' | 'no' | 'unknown' | null;
  max_msrp_cents: number | null; max_days: number | null; excluded_types: string[]; must_decline_cdw: string | null; must_pay_full: string | null;
  source_url: string | null; last_checked: string | null; vehicle_value_cents: number | null; vehicle_value_source: 'black_book' | 'estimate' | null;
  vehicle_types: string[]; rental_days: number; paid_brand: string | null;
}
export interface CardPick { card_id: string | null; card_other: string | null; label: string | null; check: CardProductCheck; at_confirm?: CardProductCheck | null }
export type ProofPageKind = 'pink_slip' | 'endorsement' | 'card_benefit';
export interface ProofPage { id: string; status: 'submitted' | 'approved' | 'rejected'; uploaded_at: string; mime_type: string | null; reject_reason?: string | null; bucket?: string; path?: string }
export interface RenterCoverage {
  option: 1 | 2 | 3 | 4 | null; option_label: string; confirmed: boolean; confirmed_at: string | null; booking_status: string;
  return_date: string; min_policy_expiry: string; pickup_at: string; vehicle_class: string | null; rental_days: number;
  can_change: boolean; protection_plan_line: boolean; protection_plan_requested: boolean; card: CardCheck; max_pages: number;
  /** 0890: the last time staff switched this booking between card coverage and the Protection Plan */
  /** 1400: the card picked from the list and the database's check of it */
  card_pick?: CardPick | null;
  /** 1401: the OPCF 27 pages still to send ("pink slip", "OPCF 27 endorsement"), and whether payment waits for them */
  opcf27_missing?: string[]; opcf27_before_payment?: boolean; page_kinds?: Record<string, ProofPageKind>;
  last_switch?: null | { at: string; direction: 'to_plan' | 'to_card'; from_label: string; to_label: string; total_before_cents: number; total_after_cents: number; note: string | null };
  proof: null | {
    id: string; option: number; status: 'submitted' | 'confirmed' | 'rejected'; rejection_reason: string | null;
    insurer_name: string | null; policy_number: string | null; policy_expiry: string | null;
    card_brand: string | null; card_last4: string | null; renter_confirmed_at: string | null; confirmation_text: string | null; pages: ProofPage[];
  };
}
export interface ReviewCoverage {
  option: 1 | 2 | 3 | 4 | null; option_label: string; confirmed: boolean; return_date: string; vehicle_class: string | null; rental_days: number;
  booking_status: string; card: CardCheck; protection_plan_line: boolean;
  card_pick?: CardPick | null; opcf27_missing?: string[]; page_kinds?: Record<string, ProofPageKind>;
  proof: null | {
    id: string; coverage_option: number; status: 'submitted' | 'confirmed' | 'rejected'; rejection_reason: string | null;
    insurer_name: string | null; policy_number: string | null; policy_expiry: string | null; policy_valid: boolean;
    card_brand: string | null; card_last4: string | null; card_funding: Funding | null; cardholder_name: string | null; name_matches: boolean | null;
    card_is_card_on_file: boolean; renter_confirmed_at: string | null; confirmation_text: string | null; vehicle_class_label: string | null; rental_days: number | null;
    submitted_at: string | null; confirmed_at: string | null; pages: ProofPage[];
  };
}
