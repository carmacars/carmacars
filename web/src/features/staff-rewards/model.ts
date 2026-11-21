// Staff rewards (release 48, migration 3261): what the door's my_rewards read returns (app.staff_perk_state), and the
// words and sums of the My rewards card. Pure: the card, the page and the unit tests read it. Every number comes from
// Program settings through the database; nothing here decides who gets what.
export interface StaffTier { code: 'member' | 'silver' | 'gold'; name: string; days: number; bps: number; bonus_days?: number }
export interface Progress { label: string; per: number; total: number; toward: number; left: number }
export interface FreeLot { days: number; left: number; expires_on: string; earned_on: string; source: string }
export interface FreeCode { code: string; days: number; valid_until: string | null; status: string; booking_number: string | null }
export interface StaffRewards {
  member: boolean; eligible: boolean; frozen?: boolean; why_not: string | null; sales?: boolean; field?: boolean; has_renter?: boolean;
  discount?: { bps: number; code: string | null; tier: StaffTier['code']; tier_name: string };
  tiers?: StaffTier[];
  month?: { label: string; days: number; last_days: number; next: { name: string; at: number; left: number } | null };
  progress?: { sales?: Progress; field?: Progress };
  free_days?: { balance: number; lots: FreeLot[]; codes: FreeCode[] };
  top_seller_days?: number;
  rules?: string[];
}

/** "15%", "12.5%" */
export const pct = (bps: number) => `${bps % 100 === 0 ? bps / 100 : (bps / 100).toFixed(1)}%`;
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
export const days = (n: number) => plural(n, 'day', 'days');

/** A bar's fill from 0 to 1, never past the ends. */
export function fill(toward: number, per: number): number {
  if (!(per > 0)) return 0;
  return Math.max(0, Math.min(1, toward / per));
}
/** The line under a progress bar: how far to the next free day. */
export function progressLine(p: Progress): string {
  const what = /handover/i.test(p.label) ? ['handover', 'handovers'] as const : ['rental day', 'rental days'] as const;
  return `${p.toward} of ${p.per} ${what[1]}: ${plural(p.left, what[0], what[1])} to your next free day.`;
}
/** The line under the month's tier bar. */
export function tierLine(r: StaffRewards): string {
  const m = r.month; const d = r.discount;
  if (!m || !d) return '';
  if (!m.next) return `${plural(m.days, 'rental day', 'rental days')} booked in ${m.label}. You are at the top tier: ${pct(d.bps)} off.`;
  return `${plural(m.days, 'rental day', 'rental days')} booked in ${m.label}: ${m.next.left} more to ${m.next.name}.`;
}
/** The month's bar: toward the next tier (full at the top tier). */
export function tierFill(r: StaffRewards): number {
  const m = r.month;
  if (!m) return 0;
  return m.next ? fill(m.days, m.next.at) : 1;
}
/** Free days ending within 30 days of `today` (YYYY-MM-DD), soonest first: the card says so. */
export function endingSoon(lots: FreeLot[], today: string): FreeLot[] {
  const t = Date.parse(`${today}T12:00:00Z`);
  return lots.filter((l) => l.left > 0 && Date.parse(`${l.expires_on}T12:00:00Z`) >= t && Date.parse(`${l.expires_on}T12:00:00Z`) - t <= 30 * 86_400_000)
    .sort((a, b) => a.expires_on.localeCompare(b.expires_on));
}
/** The choices of the Get a code form: 1 up to the balance, at most 7 for one rental. */
export const codeDayOptions = (balance: number): number[] => Array.from({ length: Math.max(0, Math.min(7, Math.floor(balance))) }, (_, i) => i + 1);
/** The one line of the card's head. */
export function headline(r: StaffRewards): string {
  if (!r.eligible || !r.discount) return r.frozen ? 'Your perks are frozen' : 'Rental perks are not on for this account';
  const free = r.free_days?.balance ?? 0;
  return `${pct(r.discount.bps)} off your own rentals${free > 0 ? ` and ${plural(free, 'free day', 'free days')} to use` : ''}`;
}
export const fmtDay = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${d.slice(0, 10)}T12:00:00Z`));
