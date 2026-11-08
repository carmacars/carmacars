import { money } from '../../lib/format.ts';

// The coverage switch of a booking (migration 0890): what the booking page says before and after "Switch to the Protection
// Plan" or "Switch to card coverage". The database prices it and decides who may; this file only words the answers.
export interface SwitchState {
  booking_number: string; status: string; option: number | null; option_label: string; may: boolean; why_not: string | null; is_offer: boolean;
  to_plan: { available: boolean; problem: string | null; amount_cents: number | null; hst_cents: number | null; total_cents: number | null; new_total_cents: number | null };
  to_card: { available: boolean; problem: string | null; option: number; option_label: string; plan_paid: boolean; removes_cents: number };
  total_cents: number; open_cents: number;
  history: Array<{ id: string; direction: 'to_plan' | 'to_card'; from_label: string; to_label: string; status: string; total_before_cents: number; total_after_cents: number; note: string | null; by: string | null; at: string }>;
}
export interface SwitchResult {
  direction: 'to_plan' | 'to_card'; was: string; status: string; total_before_cents: number; total_after_cents: number; difference_cents: number; open_cents: number;
  offer_version: number | null; refund_id: string | null; tasks_cleared: number; restored: number;
}
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const OFFER = ['requested', 'offered', 'pending_payment'];

/** What pressing "Switch to the Protection Plan" will do, before it is pressed. */
export function planPreview(s: SwitchState): string {
  const p = s.to_plan;
  if (p.amount_cents === null || p.total_cents === null) return '';
  const tax = Number(p.hst_cents ?? 0);
  const price = `The Protection Plan is ${fmt(p.amount_cents)}${tax ? ` plus ${fmt(tax)} HST` : ''}. The total goes from ${fmt(s.total_cents)} to ${fmt(p.new_total_cents)}.`;
  const how = OFFER.includes(s.status)
    ? 'The offer is sent again with the new price (a new version the renter approves), and the card coverage proof is no longer asked for.'
    : 'The extra is open to collect on this tab, the agreement is amended, and the card coverage proof and its review task are cleared.';
  return `${price} ${how}`;
}

/** What "Switch to card coverage" will do. */
export function cardPreview(s: SwitchState): string {
  const c = s.to_card;
  const money_ = c.removes_cents ? `The Protection Plan (${fmt(c.removes_cents)} with HST) comes off${c.plan_paid ? ': it was paid, so a refund goes to an Admin for approval' : ''}. ` : '';
  const how = OFFER.includes(s.status) ? 'The offer is sent again with the new price.' : 'The renter is emailed what changed.';
  return `${money_}The booking goes back to ${c.option_label}; the earlier proof and its tasks come back, or customer service is asked to get the proof. ${how}`;
}

/** The line shown after a switch. */
export function resultText(r: SwitchResult): string {
  const to = r.direction === 'to_plan' ? 'the Protection Plan' : 'card coverage';
  const total = `Total ${fmt(r.total_before_cents)} to ${fmt(r.total_after_cents)}.`;
  if (OFFER.includes(r.was)) return `Switched to ${to}. ${total} The renter has the new offer${r.offer_version ? ` (version ${r.offer_version})` : ''}.`;
  const open = r.open_cents > 0 ? ` ${fmt(r.open_cents)} to collect: use Collect on this tab.` : '';
  const refund = r.refund_id ? ' A refund waits for an Admin.' : '';
  return `Switched to ${to}. ${total}${open}${refund}`;
}
