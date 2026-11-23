// Gift cards, gifted rentals and vouchers (migration 3600): the pure rules the pages and the server actions share. The
// database decides every one again (app.gift_order_create, app.gift_card_claim, app.gift_booking_apply); these give the
// same answer before a request is sent, in the same words.

export type GiftKind = 'purchased' | 'gifted_rental' | 'voucher';
export type LedgerKind = 'issue' | 'redeem' | 'release' | 'refund' | 'void' | 'adjust';

export interface GiftCardRow {
  id: string; code_last4: string; kind: GiftKind; kind_label: string; status: 'pending_payment' | 'active' | 'voided' | 'cancelled';
  initial_cents: number; balance_cents: number; expires_at: string | null; usable: boolean; recipient_name: string; recipient_email: string | null;
  buyer_name: string | null; message: string | null; send_on: string | null; sent_at: string | null; claimed_at: string | null; rental_text: string | null;
  paid_at: string | null; created_at: string;
  /** Admin and Finance only */
  code?: string; buyer_email?: string | null; card_text?: string | null; issue_reason?: string | null; void_reason?: string | null; voided_at?: string | null;
  send_count?: number; issued_by_name?: string | null; voided_by_name?: string | null;
  history?: LedgerRow[]; claimed?: boolean;
}
export interface LedgerRow { id?: number; kind: LedgerKind; amount_cents: number; balance_after_cents: number; at: string; reason?: string | null; booking_number?: string | null; by_name?: string | null }

export interface GiftFacts { on: boolean; min_cents: number; max_cents: number; presets_cents: number[]; rental_max_days: number; cars: Array<{ vehicle_id: string; slug: string; name: string; daily_rate_cents: number | null }> }

/** Sign and pay (app.gift_booking_state). */
export interface BookingGiftState {
  due_cents: number; applied_cents: number; card_due_cents: number; has_saved_card: boolean; min_card_cents: number; room_cents: number;
  blocked: null | 'off' | 'not_payable' | 'nothing_due' | 'card_coverage'; deposit_cents: number;
  applications: Array<{ id: string; gift_card_id: string; code_last4: string; amount_cents: number }>;
  cards: Array<{ id: string; code_last4: string; kind_label: string; balance_cents: number; rental_text: string | null }>;
}

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/** A code as typed (spaces, dashes, lower case) in its stored form, or null (app.gift_code_norm). */
export function normCode(typed: string): string | null {
  const x = (typed ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  const body = x.length === 16 && x.startsWith('CCGC') ? x.slice(4) : x.length === 12 && !x.startsWith('CCGC') ? x : null;
  if (!body || [...body].some((c) => !ALPHABET.includes(c))) return null;
  return `CCGC-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8, 12)}`;
}

/** The amount a buyer picked or typed, in cents, or the reason it is refused (whole dollars, within the limits). */
export function amountProblem(cents: number | null, min: number, max: number): string | null {
  const span = `from ${dollars(min)} to ${dollars(max)}`;
  if (cents === null || !Number.isFinite(cents) || cents <= 0) return `Choose or type an amount ${span}.`;
  if (cents % 100 !== 0) return 'Use whole dollars.';
  if (cents < min || cents > max) return `Choose an amount ${span}.`;
  return null;
}

/** "$25" for typed amounts: the input takes dollars (paste-friendly: "$1,200", "150.00"). */
export function parseDollars(s: string): number | null {
  const t = (s ?? '').replace(/[$,\s]/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  return Math.round(Number(t) * 100);
}
const dollars = (c: number) => `$${(c / 100).toLocaleString('en-CA', { maximumFractionDigits: 2 })}`;

/** The send date the buyer picked, as the database reads it: empty or today is "now"; else a date up to a year ahead. */
export function sendDateProblem(ymd: string, today: string): string | null {
  if (!ymd) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(ymd)) return 'Pick a date, or leave it empty to send it now.';
  if (ymd < today) return 'Pick today or a later date.';
  const y = new Date(`${today}T12:00:00Z`); y.setUTCFullYear(y.getUTCFullYear() + 1);
  if (ymd > y.toISOString().slice(0, 10)) return 'Pick a date within a year.';
  return null;
}

export const emailOk = (e: string) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test((e ?? '').trim());

/** What the gift card can still pay on this booking: its balance, within what is left to pay (less the card minimum). */
export function applicable(s: Pick<BookingGiftState, 'room_cents'>, balance: number): number {
  return Math.max(0, Math.min(balance, s.room_cents));
}

/** The line under the gift card box on Sign and pay. */
export function giftLine(s: BookingGiftState, money: (c: number) => string): string {
  if (s.applied_cents <= 0) return s.cards.length ? 'Your gift card balance is used before your card.' : '';
  if (s.card_due_cents <= 0) return `Your gift cards pay all of the ${money(s.due_cents)}. The deposit is still held on your card at pickup.`;
  return `${money(s.applied_cents)} from your gift cards. ${money(s.card_due_cents)} is left to pay by card.`;
}

export const BLOCKED_TEXT: Record<NonNullable<BookingGiftState['blocked']>, string> = {
  off: 'Gift cards cannot be used right now.',
  not_payable: 'A gift card is used while the booking waits for payment.',
  nothing_due: 'Nothing is due on this booking.',
  card_coverage: 'You chose the rental coverage of your credit card, so the rental is paid on that card. Change how the car is covered to use a gift card.'
};

export const LEDGER_LABEL: Record<LedgerKind, string> = {
  issue: 'Issued', redeem: 'Used', release: 'Put back', refund: 'Refunded to the card', void: 'Voided', adjust: 'Adjusted'
};

/** One balance change in words: "Used on booking CC-10482" and the signed amount. */
export function ledgerText(l: LedgerRow, money: (c: number) => string): { label: string; amount: string } {
  const where = l.booking_number ? ` on booking ${l.booking_number}` : '';
  const label = l.kind === 'redeem' ? `Used${where}` : l.kind === 'release' ? `Put back${where ? ` from booking ${l.booking_number}` : ''}` : l.kind === 'refund' ? `Refund${where ? ` of booking ${l.booking_number}` : ''}` : LEDGER_LABEL[l.kind];
  return { label, amount: `${l.amount_cents > 0 ? '+' : '−'}${money(Math.abs(l.amount_cents))}` };
}

/** The state of a card in a word or two, for the lists. */
export function cardState(g: Pick<GiftCardRow, 'status' | 'balance_cents' | 'expires_at' | 'sent_at' | 'send_on'>, now = new Date()): string {
  if (g.status === 'voided') return 'Voided';
  if (g.status === 'pending_payment') return 'Not paid';
  if (g.status === 'cancelled') return 'Cancelled';
  if (g.expires_at && new Date(g.expires_at) <= now) return 'Ended';
  if (g.balance_cents <= 0) return 'Used up';
  if (!g.sent_at && g.send_on) return 'Scheduled';
  return 'Active';
}
