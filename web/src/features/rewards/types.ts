// CarmaCars Rewards (migration 0212): what public.my_rewards returns. No imports: Worker and `node --test`.
export interface RewardTier { code: string; name: string; min_days: number; discount_bps: number; perk: string | null }
export interface RewardsState {
  enabled: boolean; renter: boolean; balance: number; value_cents: number; point_value_cents: number; min_redeem: number; code_valid_days: number; expiry_months: number;
  expires_on: string | null; rental_days_12m: number;
  tier: { code: string; name: string; discount_bps: number; perk: string | null; promo_code: string | null };
  next_tier: { name: string; days_needed: number; discount_bps: number } | null;
  tiers: RewardTier[];
  referral_code: string; referral_url: string;
  actions: Array<{ code: string; label: string; detail: string | null; points: number; limit: string }>;
  socials: Array<{ platform: string; label: string; points: number; done: boolean }>;
  google: { url: string; points: number; bookings: Array<{ number: string; vehicle: string; returned: string; claimed: boolean }> } | null;
  site_reviews: Array<{ number: string; vehicle: string; reviewed: boolean }>;
  codes: Array<{ id: string; code: string; amount_cents: number; valid_until: string; in_use: boolean; used: boolean }>;
  ledger: Array<{ at: string; points: number; kind: string; reason: string; reversed: boolean }>;
}

/** The points a renter may redeem: whole hundreds from the minimum up to the balance. */
export function redeemSteps(balance: number, min: number): number[] {
  if (balance < min) return [];
  const out: number[] = [];
  const step = 100;
  for (let p = Math.ceil(min / step) * step; p <= balance && out.length < 12; p += p < 2000 ? step * 5 : step * 10) out.push(p);
  if (!out.includes(Math.floor(balance / step) * step) && Math.floor(balance / step) * step >= min) out.push(Math.floor(balance / step) * step);
  return out;
}
export const pointsWorth = (points: number, centsPerPoint: number) => Math.floor(points * centsPerPoint);
