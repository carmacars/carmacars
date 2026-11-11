// r35a (1303): the rideshare and delivery platforms a renter can make documents for, and the letters' facts.
export type RidesharePlatform = 'uber' | 'lyft' | 'doordash' | 'uber_eats' | 'instacart' | 'other';
export const RIDESHARE_PLATFORMS: ReadonlyArray<readonly [RidesharePlatform, string]> = [
  ['uber', 'Uber'], ['lyft', 'Lyft'], ['doordash', 'DoorDash'], ['uber_eats', 'Uber Eats'], ['instacart', 'Instacart'], ['other', 'Other']];

export interface RideshareFacts {
  open: boolean; booking_id: string; booking_number: string; status: string; pickup_at: string; return_at: string; issued_at: string;
  company: { legal_name: string | null; trade_name: string | null; address: string | null; phone: string | null; email: string | null };
  car: { year: number | null; make: string | null; model: string | null; colour: string | null; plate: string | null; vin: string | null };
  renter: string | null; drivers: string[];
  coverage: { kind: 'own_policy' | 'card' | 'plan' | 'none'; confirmed: boolean; insurer_name: string | null; policy_expiry: string | null; card_brand: string | null; card_last4: string | null;
    plan_provider: string | null } | null;
  coverage_card: { short: string | null; proof_words: string } | null;
  fleet_policy: { insurer_name: string; policy_number: string; effective_on: string; expires_on: string; named_insured: string | null } | null;
  agreement_document_id: string | null;
  requests: Array<{ id: string; platforms: RidesharePlatform[]; other_platform: string | null; created_at: string; labels: string[] }>;
}

export type LetterKind = 'coverage' | 'vehicle';
export const LETTERS: ReadonlyArray<readonly [LetterKind, string]> = [['coverage', 'Proof of insurance and coverage letter'], ['vehicle', 'Vehicle registration and ownership letter']];

/** The car in words: "2023 Toyota Corolla, white". */
export function carWords(c: RideshareFacts['car']): string {
  return [[c.year, c.make, c.model].filter(Boolean).join(' '), c.colour].filter(Boolean).join(', ');
}

/** Which platforms the renter can still pick ("other" needs its name). */
export function rideshareProblem(picked: RidesharePlatform[], other: string): string | null {
  if (!picked.length) return 'Pick at least one platform.';
  if (picked.includes('other') && other.trim().length < 2) return 'Name the other platform.';
  return null;
}
