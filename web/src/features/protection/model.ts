import { money } from '../../lib/format.ts';

// Change protection (migrations 2540, 2541): the three ways damage to the car is covered, as the booking page dialog and the
// renter's "Change my protection" show them. The database prices each option, applies the rules and refuses with the reason;
// this file only words its answers, and mirrors the coverage order (card, then OPCF 27, then the plan) for the request form.
export type Opt = 1 | 2 | 3;
export interface ProtectionOption {
  option: Opt; label: string; current: boolean; available: boolean; problem: string | null; rule?: string | null;
  applies: 'now' | 'review' | 'ask'; change_cents: number | null; new_total_cents: number; deposit_change_cents: number; needs: string;
}
export interface ProtectionRequest {
  id: string; status: 'pending' | 'approved' | 'declined' | 'withdrawn' | 'superseded'; to_option: 1 | 2; to_label: string; reason: string | null;
  decision_note: string | null; created_at: string; decided_at: string | null; insurer_name: string | null; policy_number: string | null; policy_expiry: string | null;
  proof_bucket?: string | null; proof_path?: string | null; proof_mime?: string | null;
}
export interface ProtectionOptions {
  booking_number: string; status: string; option: number | null; option_label: string; side: 'staff' | 'renter'; may: boolean; why_not: string | null;
  days: number; plan_cents: number | null; plan_hst_cents: number | null; plan_daily_cents: number | null; deposit_cents: number; total_cents: number; open_cents: number;
  options: ProtectionOption[]; request: ProtectionRequest | null; may_review?: boolean;
  card: { id: string; label: string; check: { result: string; message: string } } | null; card_ack: boolean; opcf27_ack: boolean;
  history: Array<{ id: string; from_label: string; to_label: string; total_before_cents: number; total_after_cents: number; note: string | null; side: 'staff' | 'renter'; by: string | null; at: string }>;
}
export interface ProtectionResult {
  applied?: boolean; asked?: boolean; status?: string; was?: string; to_label?: string; total_before_cents?: number; total_after_cents?: number;
  difference_cents?: number; open_cents?: number; refund_id?: string | null; offer_version?: number | null; override?: boolean; request_id?: string;
}

const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
export const TITLE: Record<Opt, string> = { 1: 'Own insurance (OPCF 27)', 2: 'Credit card coverage', 3: 'Protection Plan' };
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
export const label = (s: string) => cap(s);

/** The price line of one option: "+$123.45", "-$45.20" or "No price change". */
export function changeText(o: Pick<ProtectionOption, 'change_cents' | 'current'>): string {
  if (o.current) return 'Current';
  if (o.change_cents === null) return 'Price not set';
  if (o.change_cents === 0) return 'No price change';
  return `${o.change_cents > 0 ? '+' : '-'}${fmt(Math.abs(o.change_cents))}`;
}

/** The plan priced as the owner reads it: "$12.50 a day x 4 days = $50.00 plus HST". */
export function planText(x: Pick<ProtectionOptions, 'plan_daily_cents' | 'plan_cents' | 'plan_hst_cents' | 'days'>): string {
  if (x.plan_cents === null || x.plan_daily_cents === null) return '';
  const tax = Number(x.plan_hst_cents ?? 0);
  return `${fmt(x.plan_daily_cents)} a day x ${x.days} ${x.days === 1 ? 'day' : 'days'} = ${fmt(x.plan_cents)}${tax ? ` plus ${fmt(tax)} HST` : ''}`;
}

/** What happens once the option is chosen, for the person choosing. */
export function whatHappens(o: ProtectionOption, x: Pick<ProtectionOptions, 'status' | 'side'>): string {
  const offer = ['requested', 'offered', 'pending_payment'].includes(x.status);
  if (o.applies === 'review') return 'Send your proof: our team checks it, usually within 2 hours, and the change takes effect once approved. The Protection Plan stays until then.';
  if (o.applies === 'ask') return 'Your offer is waiting for payment: we send it again with the Protection Plan for you to approve.';
  const money_ = (o.change_cents ?? 0) > 0
    ? (x.side === 'renter' ? `You pay ${fmt(o.change_cents)} more on this page.` : `${fmt(o.change_cents)} becomes a balance to collect (Money > Collect); nothing is charged by itself.`)
    : (o.change_cents ?? 0) < 0 ? (x.side === 'renter' ? `${fmt(-Number(o.change_cents))} comes off; if it was paid, we refund it.` : `${fmt(-Number(o.change_cents))} comes off; a paid plan becomes a refund for an Admin to approve.`)
    : 'The price stays the same.';
  const doc = offer ? (x.side === 'staff' ? ' The offer is sent again for the renter to approve.' : '') : ' The agreement shows the change; sign the new version if asked.';
  return `${money_}${doc}`;
}

/** The line shown after a change. */
export function resultText(r: ProtectionResult): string {
  if (r.asked) return 'We have your choice: we send the offer again with the Protection Plan.';
  if (r.applied === false) return 'Sent for review. We let you know as soon as it is checked.';
  const total = r.total_before_cents !== undefined ? ` Total ${fmt(r.total_before_cents)} to ${fmt(r.total_after_cents)}.` : '';
  const open = (r.open_cents ?? 0) > 0 ? ` ${fmt(r.open_cents)} open to pay.` : '';
  const refund = r.refund_id ? ' A refund waits for approval.' : '';
  return `Changed to ${r.to_label ?? 'the new option'}.${total}${open}${refund}${r.override ? ' (Admin override recorded.)' : ''}`;
}

export interface CardCheck { result: 'covered' | 'not_covered' | 'review'; card_id: string | null; message: string }
/** The coverage order (2541), the same words as app.coverage_choice_problem: card coverage only with a card from the list that
 *  covers the car and the promise to pay with it; OPCF 27 only with the promise to upload the policy; otherwise the plan. */
export function coverageChoiceProblem(option: number, check: CardCheck | null, cardAck: boolean, opcfAck: boolean): string | null {
  if (option === 2 && (!check || !check.card_id)) return 'Pick your credit card from the list to check its rental car coverage first';
  if (option === 2 && check && check.result !== 'covered') return `${check.message || 'That card does not cover this car.'} Credit card coverage needs a card on our list that covers this car: choose OPCF 27 on your own auto policy, or the Protection Plan.`;
  if (option === 2 && !cardAck) return 'Tick that you will pay for the rental with this card: its coverage counts only on the card that paid';
  if (option === 1 && !opcfAck) return 'Tick that you will upload your auto policy with the OPCF 27 endorsement (the pink slip and the endorsement page)';
  return null;
}
export const CARD_ACK = 'I will pay for this rental with this credit card. I understand its coverage counts only on the card that paid.';
export const OPCF_ACK = 'I will upload my auto policy: the pink slip and the OPCF 27 endorsement page. The car is not handed over until it is approved.';
