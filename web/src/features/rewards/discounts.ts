// r40 (2423): the renter's saved discounts (public.server_my_discounts), put in words for the Rewards page, the compact
// card on /account and the request form's "Use a saved discount" picker. No imports: Worker and `node --test`.

export type DiscountKind = 'points' | 'tier' | 'free_day' | 'referral' | 'game' | 'offer' | 'personal';
export type DiscountStatus = 'open' | 'on_request' | 'used' | 'expired';
export interface SavedDiscount {
  code: string; kind: DiscountKind; what: string; applies_to: string;
  percent_bps: number | null; amount_cents: number | null; free_days: number | null;
  valid_until: string | null; ends: string | null; days_left: number | null;
  status: DiscountStatus; booking_number: string | null; company_funded?: boolean;
}

const KIND: Record<DiscountKind, string> = {
  points: 'From your points', tier: 'Your tier code', free_day: 'Your free day (Black)', referral: 'Referral credit',
  game: 'Prize code', offer: 'An offer for you', personal: 'From our team'
};

export interface DiscountRow extends SavedDiscount {
  source: string;
  /** "Unused", "On request R-1234", "Used on booking R-1234", "Expired" */
  state: string;
  /** under 30 days left on an unused code: the page shows a live countdown */
  countdown: boolean;
  /** "Ends Nov 30 (12 days left)", "No end date", "Ended Nov 2" */
  until: string;
  copyable: boolean;
}

const left = (n: number | null) => (n === null ? '' : n === 0 ? 'ends today' : n === 1 ? '1 day left' : `${n} days left`);

export function discountRow(d: SavedDiscount): DiscountRow {
  const state = d.status === 'open' ? 'Unused' : d.status === 'on_request' ? `On request ${d.booking_number ?? ''}`.trim()
    : d.status === 'used' ? (d.booking_number ? `Used on booking ${d.booking_number}` : 'Used') : 'Expired';
  const until = d.status === 'expired' ? (d.ends ? `Ended ${d.ends}` : 'Ended') : d.ends ? `Ends ${d.ends}${d.days_left !== null ? ` (${left(d.days_left)})` : ''}` : 'No end date';
  return { ...d, source: KIND[d.kind] ?? KIND.personal, state, until, countdown: d.status === 'open' && d.days_left !== null && d.days_left < 30, copyable: d.status === 'open' };
}

/** Every code in order (unused first, as the database sends them), in words. */
export const discountRows = (list: SavedDiscount[] | null | undefined): DiscountRow[] => (Array.isArray(list) ? list : []).filter((d) => !!d && typeof d.code === 'string').map(discountRow);

/** The codes the renter can use now (the request form's picker), soonest to end first. */
export function usableDiscounts(list: SavedDiscount[] | null | undefined): Array<Pick<SavedDiscount, 'code' | 'what' | 'days_left'>> {
  return discountRows(list).filter((d) => d.status === 'open')
    .sort((a, b) => (a.days_left ?? 1e9) - (b.days_left ?? 1e9))
    .map(({ code, what, days_left }) => ({ code, what, days_left }));
}
