// Owner rewards (release 48, migration 3262): what public.owner_portal_rewards returns (app.owner_reward_state), and the
// words and sums of the Rewards tab. Pure: the tab and the unit tests read it. Every number is the database's.
export type KitKind = 'merch_kit' | 'merch_kit_premium';
export interface Milestone { kind: KitKind; name: string; months: number; reached: boolean; months_left: number;
  request: { id: string; status: 'requested' | 'shipped'; requested_at: string; shipped_at: string | null; tracking: string | null; city: string | null } | null }
export interface OwnerAddress { name: string | null; line1: string | null; line2: string | null; city: string | null; province: string | null; postal_code: string | null; phone: string | null }
export interface OwnerRewards {
  on: boolean; why?: string; since?: string | null; months?: number; has_renter?: boolean;
  fleet?: { bps: number; code: string | null; car_down_now: boolean; cars: Array<{ vehicle_id: string; name: string; status: string; down: boolean }> };
  upgrade?: { id: string; status: 'requested' | 'approved' | 'declined' | 'cancelled' | 'shipped'; created_at: string; decision_note: string | null; code: string | null; amount_cents: number | null; valid_until: string | null } | null;
  friends?: { bps: number; kickback_bps: number; code: string; link: string; rentals: number; earned_cents: number;
    recent: Array<{ booking_number: string; at: string; status: string; kickback_cents: number | null }> };
  refer_owner?: { cents: number; live_days: number; link: string; referred: Array<{ name: string; live_at: string | null; credited: boolean }> };
  milestones?: Milestone[];
  address?: OwnerAddress;
  birthday?: { cents: number; known: boolean; code: { code: string; valid_until: string | null; status: string } | null };
  perks?: Array<{ name: string; detail: string }>;
  history?: Array<{ at: string; title: string; detail: string | null; amount_cents: number | null; kind: string }>;
  rules?: string[];
}

export const pct = (bps: number) => `${bps % 100 === 0 ? bps / 100 : (bps / 100).toFixed(1)}%`;
export const dollars = (cents: number) => new Intl.NumberFormat('en-CA', { style: 'currency', currency: 'CAD', minimumFractionDigits: cents % 100 === 0 ? 0 : 2 }).format(cents / 100).replace('CA', '');
export const fmtDay = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'America/Toronto' }).format(new Date(d.length === 10 ? `${d}T12:00:00Z` : d));

/** A milestone's bar from 0 to 1. */
export function milestoneFill(months: number, m: Milestone): number {
  if (m.reached) return 1;
  return Math.max(0, Math.min(1, months / Math.max(m.months, 1)));
}
/** Where a milestone stands, in words: the button, the wait, or the status. */
export function milestoneState(m: Milestone): { state: 'shipped' | 'requested' | 'ready' | 'waiting'; line: string } {
  if (m.request?.status === 'shipped') {
    return { state: 'shipped', line: `Shipped${m.request.shipped_at ? ` ${fmtDay(m.request.shipped_at)}` : ''}${m.request.city ? ` to ${m.request.city}` : ''}.${m.request.tracking ? ` Tracking: ${m.request.tracking}` : ''}` };
  }
  if (m.request?.status === 'requested') return { state: 'requested', line: `Redeemed ${fmtDay(m.request.requested_at)}. We are getting it ready to ship${m.request.city ? ` to ${m.request.city}` : ''}.` };
  if (m.reached) return { state: 'ready', line: 'Ready to redeem. Confirm where to send it.' };
  return { state: 'waiting', line: `${m.months_left} more ${m.months_left === 1 ? 'month' : 'months'} to go.` };
}
/** What is missing from the address the owner confirms (the database checks the same). */
export function addressProblem(a: { name: string; line1: string; city: string; postal_code: string }): string | null {
  if (!a.name.trim()) return 'Enter the name on the parcel.';
  if (!a.line1.trim()) return 'Enter the street address.';
  if (!a.city.trim()) return 'Enter the city.';
  if (!/^[A-Za-z]\d[A-Za-z][ -]?\d[A-Za-z]\d$/.test(a.postal_code.trim()) && !/^\d{5}(-\d{4})?$/.test(a.postal_code.trim())) return 'Enter the postal code, for example M5V 1A1.';
  return null;
}
/** The owner's first line on the tab. */
export function headline(r: OwnerRewards): string {
  if (!r.on) return r.why ?? 'Owner rewards are not on for this account.';
  const ready = (r.milestones ?? []).filter((m) => m.reached && !m.request).length;
  const parts = [`${pct(r.fleet?.bps ?? 0)} off other CarmaCars cars while yours is out`, `${pct(r.friends?.bps ?? 0)} off for your friends and family`];
  return `${parts.join(', ')}${ready ? `, and ${ready === 1 ? 'a merch kit' : `${ready} merch kits`} ready to redeem` : ''}.`;
}
