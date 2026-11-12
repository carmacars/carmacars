// CarmaCars Rewards (migration 0214): what public.my_rewards returns. No imports: Worker and `node --test`.
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
  /** r40 (2421): the tiers by points earned in the last 12 months, with their perks; null on an older database */
  ladder?: Ladder | null;
}

/** r40 (2421): a tier's perk (Admin > Rewards edits the words and which tier has it; higher tiers keep the lower ones'). */
export interface TierPerk { code: 'instant_book' | 'any_car' | 'free_day'; label: string; detail: string | null }
export interface LadderTier { code: string; name: string; min_points: number; perks: TierPerk[] }
export interface Ladder {
  points_12m: number;
  /** the renter's tier, or null below the first (a Member, in words only) */
  tier_code: string | null;
  tiers: LadderTier[];
  free_day: { code: string; valid_until: string | null; used: boolean } | null;
  any_car_hours: number;
}

export type TierState = 'done' | 'now' | 'later';
export interface LadderView {
  current: LadderTier | null;
  next: LadderTier | null;
  /** points still to earn for the next tier (0 at the top) */
  need: number;
  /** 0..1 along the whole ladder, each tier an equal step (so Gold is not a sliver next to Black) */
  progress: number;
  /** "1,240 more points to Platinum", "You are at the top: Black" */
  line: string;
  states: Array<{ tier: LadderTier; state: TierState }>;
  /** every perk the renter has now (cumulative) */
  perks: TierPerk[];
}

const n = (v: number) => Math.round(v).toLocaleString('en-CA');

/** Where the renter stands on the ladder (pure; the Rewards page and the unit test). */
export function ladderView(l: Ladder): LadderView {
  const tiers = [...l.tiers].sort((a, b) => a.min_points - b.min_points);
  const pts = Math.max(0, l.points_12m);
  const reached = tiers.filter((t) => t.min_points <= pts);
  const current = reached[reached.length - 1] ?? null;
  const next = tiers.find((t) => t.min_points > pts) ?? null;
  const i = current ? tiers.indexOf(current) + 1 : 0;
  const lo = current?.min_points ?? 0;
  const part = next ? Math.max(0, Math.min(1, (pts - lo) / Math.max(1, next.min_points - lo))) : 0;
  const progress = tiers.length ? Math.min(1, (i + part) / tiers.length) : 0;
  const need = next ? next.min_points - pts : 0;
  const line = next ? `${n(need)} more ${need === 1 ? 'point' : 'points'} to ${next.name}` : current ? `You are at the top: ${current.name}` : 'Earn points to reach the first tier';
  const states = tiers.map((t) => ({ tier: t, state: (t.min_points <= pts ? 'done' : t === next ? 'now' : 'later') as TierState }));
  const perks = reached.flatMap((t) => t.perks);
  return { current, next, need, progress, line, states, perks };
}

/** A tier's rank (0 below the first), for the celebration when it goes up. */
export const tierRank = (l: Pick<Ladder, 'tiers' | 'tier_code'>, code: string | null = l.tier_code) =>
  code ? [...l.tiers].sort((a, b) => a.min_points - b.min_points).findIndex((t) => t.code === code) + 1 : 0;

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
