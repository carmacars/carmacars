// Email the renter (and the adjuster) from a booking (migration 0187): who may be written to, and from which sender.
// The database decides again (app.booking_email_send); these only shape the form.
//   - The renter: from CarmaCars (bookings@carmacars.ca, replies to the shared bookings inbox), or, when an insurer pays
//     all or part of the booking, from Blind Spot Car Rental (insurance).
//   - The adjuster: only on an insurer-billed booking with the adjuster's email recorded, always from Blind Spot Car Rental.

import { emailBudgetLine } from '../usage/model.ts';

export type Recipient = 'renter' | 'adjuster';
export type Sender = 'carmacars' | 'blindspot';

export interface Conversation {
  booking: string; booking_id: string; status: string; bill_to: string; insurer_billed: boolean;
  insurer_name: string | null; claim_number: string | null;
  renter: { name: string | null; email: string | null } | null;
  adjuster: { name: string | null; email: string | null } | null;
  messages: Array<{ id: string; direction: 'inbound' | 'outbound'; channel: string; subject: string | null; body: string | null; at: string; by: string; from: string | null; to: string | null; adjuster: boolean }>;
  emails: Array<{ id: string; code: string; subject: string; to: string | null; audience: string; from: string | null; status: string; reason: string | null; at: string; sent_at: string | null }>;
  quick_replies: Array<{ id: string; title: string; body: string }>;
  usage: { total: number; cap: number; cf_state?: string | null; cf_counted?: boolean | null; cf_budget?: number | null; resend_budget?: number | null;
    capacity?: number | null; limited_by?: string | null; cf_reason?: string | null; setting?: number | null };
}

export const SENDERS: Record<Sender, { label: string; address: string }> = {
  carmacars: { label: 'CarmaCars', address: 'CarmaCars <bookings@carmacars.ca>' },
  blindspot: { label: 'Blind Spot Car Rental (insurance)', address: 'Blind Spot Car Rental <blindspotcarrental@carmacars.ca>' },
};

type Facts = Pick<Conversation, 'insurer_billed' | 'renter' | 'adjuster'>;

/** Who the form may write to. The renter whenever the booking has one; the adjuster on an insurer-billed booking with their email. */
export function recipientChoices(c: Facts): Array<[Recipient, string]> {
  const out: Array<[Recipient, string]> = [];
  if (c.renter) out.push(['renter', c.renter.name ? `The renter, ${c.renter.name}` : 'The renter']);
  if (c.insurer_billed && c.adjuster?.email) out.push(['adjuster', c.adjuster.name ? `The adjuster, ${c.adjuster.name}` : 'The adjuster']);
  return out;
}

/** The senders offered for a recipient: the adjuster always hears from Blind Spot Car Rental. */
export function senderChoices(c: Facts, to: Recipient): Array<[Sender, string]> {
  if (to === 'adjuster') return [['blindspot', SENDERS.blindspot.label]];
  return c.insurer_billed ? [['carmacars', SENDERS.carmacars.label], ['blindspot', SENDERS.blindspot.label]] : [['carmacars', SENDERS.carmacars.label]];
}

/** The sender to start with: CarmaCars for the renter, Blind Spot Car Rental for the adjuster. A choice that is no longer offered falls back. */
export function pickSender(c: Facts, to: Recipient, wanted?: Sender | null): Sender {
  const offered = senderChoices(c, to).map(([k]) => k);
  return wanted && offered.includes(wanted) ? wanted : (offered[0] ?? 'carmacars');
}

/** Why the form cannot send yet (null when it can). The database refuses the same. */
export function emailProblem(subject: string, body: string): string | null {
  if (!subject.trim()) return 'Write the subject.';
  if (subject.trim().length > 150) return 'Keep the subject under 150 characters.';
  if (!body.trim()) return 'Write the message.';
  if (body.length > 4000) return 'Keep the message under 4,000 characters.';
  return null;
}

/** Plain words for an email of the booking in the list (its catalogue code otherwise, without underscores). */
export function emailKind(code: string): string {
  if (code === 'renter_staff_message') return 'Message from staff';
  if (code === 'insurance_staff_message') return 'Message from Blind Spot Car Rental';
  if (code === 'insurer_invoice') return 'Insurer invoice';
  return code.replace(/^(renter|insurer)_/, '').replace(/_/g, ' ').replace(/^./, (s) => s.toUpperCase());
}

/** Where today's emails stand against the daily limit, in a line; a warning from 80%. */
export function usageLine(u: Conversation['usage']): { text: string; warn: boolean } {
  const warn = u.cap > 0 && u.total >= Math.ceil(u.cap * 0.8);
  const tail = warn ? 'Close to the limit: an email past it waits until midnight.' : 'Messages to renters go before digests and marketing.';
  // r35 (0900): with the pace read's budgets the line says why the cap is that number
  if (typeof u.cf_budget === 'number' && typeof u.resend_budget === 'number') {
    return { text: `${emailBudgetLine({ used: u.total, cap: u.cap, cf_state: u.cf_state, cf_counted: u.cf_counted, cf_budget: u.cf_budget, resend_budget: u.resend_budget, capacity: u.capacity, limited_by: u.limited_by, cf_reason: u.cf_reason, setting: u.setting })}. ${tail}`, warn };
  }
  return { text: `${u.total} of ${u.cap} emails sent today (the day's sending limit). ${tail}`, warn };
}
