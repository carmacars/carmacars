import type { Funding } from './card';

// What app.renter_coverage and app.coverage_review_facts return (the coverage proof migration).
export interface CardCheck {
  eligible: boolean; problem: 'no_card' | 'not_credit' | 'name_mismatch' | null; message: string | null;
  payment_method_id: string | null; brand: string | null; last4: string | null; funding: Funding | null; country: string | null;
  cardholder_name: string | null; renter_name?: string | null; name_matches: boolean; vehicle_class: string | null; rental_days: number;
}
export interface ProofPage { id: string; status: 'submitted' | 'approved' | 'rejected'; uploaded_at: string; mime_type: string | null; reject_reason?: string | null; bucket?: string; path?: string }
export interface RenterCoverage {
  option: 1 | 2 | 3 | null; option_label: string; confirmed: boolean; confirmed_at: string | null; booking_status: string;
  return_date: string; min_policy_expiry: string; pickup_at: string; vehicle_class: string | null; rental_days: number;
  can_change: boolean; protection_plan_line: boolean; protection_plan_requested: boolean; card: CardCheck; max_pages: number;
  proof: null | {
    id: string; option: number; status: 'submitted' | 'confirmed' | 'rejected'; rejection_reason: string | null;
    insurer_name: string | null; policy_number: string | null; policy_expiry: string | null;
    card_brand: string | null; card_last4: string | null; renter_confirmed_at: string | null; confirmation_text: string | null; pages: ProofPage[];
  };
}
export interface ReviewCoverage {
  option: 1 | 2 | 3 | null; option_label: string; confirmed: boolean; return_date: string; vehicle_class: string | null; rental_days: number;
  booking_status: string; card: CardCheck; protection_plan_line: boolean;
  proof: null | {
    id: string; coverage_option: number; status: 'submitted' | 'confirmed' | 'rejected'; rejection_reason: string | null;
    insurer_name: string | null; policy_number: string | null; policy_expiry: string | null; policy_valid: boolean;
    card_brand: string | null; card_last4: string | null; card_funding: Funding | null; cardholder_name: string | null; name_matches: boolean | null;
    card_is_card_on_file: boolean; renter_confirmed_at: string | null; confirmation_text: string | null; vehicle_class_label: string | null; rental_days: number | null;
    submitted_at: string | null; confirmed_at: string | null; pages: ProofPage[];
  };
}
