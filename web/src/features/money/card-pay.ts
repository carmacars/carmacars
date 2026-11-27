// Hotfix 3650: card payments on or off, and paying by e-Transfer when they are off. The one answer comes from the
// database (app.card_payments_state: the Program setting card_payments and the processor's own state); this file holds
// the words and the small rules the renter pages, the staff Money tab and the tests share. Pure.

/** The card processor seam: stripe today, helcim once its adapter is in, off when cards cannot be taken. */
export type CardProvider = 'stripe' | 'helcim' | 'off';

export interface CardPayments {
  on: boolean; provider: CardProvider; configured_provider: 'stripe' | 'helcim'; setting_on: boolean;
  reason: 'setting' | 'processor' | null; e_transfer_email: string | null;
  /** 5110: the company's deposit account for direct deposit (Program settings cc_pay_*, typed by an Admin); null when not set */
  direct_deposit?: { account_name: string | null; bank: string | null; institution: string | null; transit: string | null; account: string } | null;
  processor?: { charges_enabled: boolean; payouts_enabled: boolean; disabled_reason: string | null; checked_at: string | null; paused_since: string | null };
}

/** What the renter sends by e-Transfer on one booking (app.renter_etransfer_state). */
export interface RenterEtransfer {
  card: CardPayments; booking_number: string; status: string; e_transfer_email: string | null;
  rental_cents: number; rental_cash: boolean; deposit_cents: number; deposit_method: string; deposit_card_cents: number; may_report: boolean;
  open: { report_number: string; amount_cents: number; covers: 'rental' | 'deposit' | 'both'; reported_at: string } | null;
  declined: { report_number: string; amount_cents: number; reason: string; decided_at: string } | null;
}

/** Card payments are on unless the state says off; no state (a read that failed) keeps the card as before. */
export const cardOn = (s: Pick<CardPayments, 'on'> | null | undefined): boolean => s?.on !== false;

/** The staff note when cards are paused (Money tab, field tools). */
export const CARD_PAUSED_TITLE = 'Card payments are paused';
export function cardPausedWhy(s: Pick<CardPayments, 'reason'> | null | undefined): string {
  return s?.reason === 'setting' ? 'An Admin turned card payments off in Program settings.'
    : 'The card processor is not taking payments right now.';
}

/** What a renter pays by e-Transfer now: the rental (when the booking takes e-Transfer for it) and the deposit. */
export function etransferParts(s: Pick<RenterEtransfer, 'rental_cents' | 'rental_cash' | 'deposit_cents' | 'deposit_method'>) {
  const rental = s.rental_cash ? 0 : Math.max(0, s.rental_cents);
  const deposit = s.deposit_method === 'e_transfer' ? Math.max(0, s.deposit_cents) : 0;
  return { rental, deposit, total: rental + deposit, cashRental: s.rental_cash ? Math.max(0, s.rental_cents) : 0, cashDeposit: s.deposit_method === 'cash' ? Math.max(0, s.deposit_cents) : 0 };
}

/** The covers value of a report for the amount sent: both when it is the rental and the deposit together. */
export function coversFor(p: { rental: number; deposit: number }, choice: 'all' | 'rental' | 'deposit'): 'rental' | 'deposit' | 'both' {
  if (choice === 'rental') return 'rental';
  if (choice === 'deposit') return 'deposit';
  return p.rental > 0 && p.deposit > 0 ? 'both' : p.rental > 0 ? 'rental' : 'deposit';
}

/** The amount for a choice: all of it, the rental only or the deposit only. */
export function amountFor(p: { rental: number; deposit: number }, choice: 'all' | 'rental' | 'deposit'): number {
  return choice === 'rental' ? p.rental : choice === 'deposit' ? p.deposit : p.rental + p.deposit;
}

/** The message staff copy and send to the renter (text, email or WhatsApp): the email, the message and the amounts. */
export function etransferMessage(x: { firstName?: string | null; bookingNumber: string; email: string | null; rentalCents: number; depositCents: number; fmt: (c: number) => string }): string {
  const lines = [
    `Hi${x.firstName ? ` ${x.firstName}` : ''}, card payments are paused for a short while, so please pay by Interac e-Transfer:`,
    `Send to: ${x.email ?? 'our e-Transfer email'}`,
    `Message: ${x.bookingNumber}`
  ];
  if (x.rentalCents > 0) lines.push(`Rental: ${x.fmt(x.rentalCents)}`);
  if (x.depositCents > 0) lines.push(`Refundable deposit: ${x.fmt(x.depositCents)} (given back by e-Transfer after the trip)`);
  if (x.rentalCents > 0 && x.depositCents > 0) lines.push(`Total: ${x.fmt(x.rentalCents + x.depositCents)}`);
  lines.push('Then upload the e-Transfer screenshot on your booking (Sign and pay), or reply with it. Thank you!');
  return lines.join('\n');
}
