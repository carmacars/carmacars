// The booking's Money tab in two panels (release 29, C0): Rental charges and Security deposit, kept apart. Pure: the
// panels and the unit tests share it (money-panels.test.ts).
export type DepositWord = 'Not collected' | 'Held' | 'Hold expired' | 'Charged' | 'Released' | 'Partly kept' | 'Waived' | 'No deposit';
export interface DepositRow { hold_expires_at?: string | null; method: string; paid_method?: string | null; status: string; amount_cents: number; captured_cents?: number; released_cents?: number; applied_cents?: number; held_back_cents?: number }
export interface PayRow { purpose: string; kind: string; method: string; amount_cents: number; status: string; covers: string | null; voided?: boolean }

/** The deposit's status as one word. */
export function depositWord(d: DepositRow | null, depositCents: number, waived = false, now = Date.now(), moneyIn: number | null = null): DepositWord {
  if (waived) return 'Waived';
  if (!d || ['pending', 'failed'].includes(d.status)) return depositCents > 0 ? 'Not collected' : 'No deposit';
  // r44: a deposit charged or taken in cash or by e-Transfer is money received: with no such money on the booking (a
  // payment that failed, was voided or was never made), it is not "Charged" (a card hold is checked by its own status)
  if (moneyIn !== null && moneyIn <= 0 && d.method !== 'card_hold' && d.status === 'captured') return depositCents > 0 ? 'Not collected' : 'No deposit';
  // r33 (0750): a card hold past its expiry (or ended by Stripe) can no longer be kept from
  if (d.status === 'held' && d.method === 'card_hold' && d.hold_expires_at && new Date(d.hold_expires_at).getTime() <= now) return 'Hold expired';
  if (d.status === 'held') return 'Held';
  const kept = Number(d.applied_cents ?? 0) + Number(d.held_back_cents ?? 0) + (d.method === 'card_hold' ? Number(d.captured_cents ?? 0) : 0);
  if (d.status === 'settled' || Number(d.released_cents ?? 0) > 0) return kept > 0 ? 'Partly kept' : 'Released';
  if (d.status === 'captured') return d.method === 'card_hold' ? 'Partly kept' : 'Charged';
  if (d.status === 'carried_forward') return 'Charged';
  return 'Not collected';
}

/** The deposit's next step, for the one primary button. */
export function depositNext(word: DepositWord, bookingStatus: string): 'collect' | 'settle' | 'held' | 'expired' | 'none' {
  if (word === 'Hold expired') return 'expired';
  if (word === 'Not collected') return ['pending_payment', 'confirmed', 'on_rent'].includes(bookingStatus) ? 'collect' : 'none';
  if (word === 'Held') return ['returned', 'closed'].includes(bookingStatus) ? 'settle' : 'held';
  if (word === 'Charged') return ['returned', 'closed'].includes(bookingStatus) ? 'settle' : 'none';
  return 'none';
}

export const isDeposit = (p: Pick<PayRow, 'purpose' | 'covers'>) => p.purpose === 'deposit' || p.covers === 'deposit';
const counted = (p: PayRow) => !p.voided && ['succeeded', 'partially_refunded', 'refunded'].includes(p.status);

/** What was paid for the rental (charges less refunds, never the deposit) and in all (with a deposit charged or taken in
 *  cash; a card hold is not money paid). */
export function paidTotals(rows: PayRow[]): { rental_cents: number; deposit_cents: number; total_cents: number } {
  let rental = 0, deposit = 0;
  for (const p of rows) {
    if (!counted(p)) continue;
    const sign = p.kind === 'refund' || p.kind === 'release' ? -1 : p.kind === 'charge' || p.kind === 'capture' ? 1 : 0;
    if (!sign) continue;
    if (isDeposit(p)) deposit += sign * p.amount_cents; else rental += sign * p.amount_cents;
  }
  return { rental_cents: rental, deposit_cents: Math.max(0, deposit), total_cents: rental + Math.max(0, deposit) };
}

/** The open rental balance (rental and fees; later charges apart). */
export function rentalDue(parts: Array<{ covers: string; open_cents: number }>): { due_cents: number; later_cents: number } {
  const open = (c: string) => Math.max(0, parts.find((p) => p.covers === c)?.open_cents ?? 0);
  return { due_cents: open('rental') + open('fees'), later_cents: open('later') };
}

/** r44: a failed card attempt, as the payments list shows it: settled by a payment recorded another way (one that names
 *  it and is not voided), nothing owing for its part any more, or open. Read from the money recorded, never assumed. */
export function failedAttemptState(p: { id: string; purpose: string }, manual: Array<{ settles_payment_id?: string | null; voided_at: string | null }>,
  parts: Array<{ covers: string; open_cents: number }> | null): 'settled' | 'nothing_owing' | 'open' {
  if (manual.some((m) => m.settles_payment_id === p.id && !m.voided_at)) return 'settled';
  if (!parts) return 'open';
  const open = (c: string) => Math.max(0, parts.find((x) => x.covers === c)?.open_cents ?? 0);
  const owing = p.purpose === 'deposit' ? null : p.purpose === 'later_charge' || p.purpose === 'damage' ? open('later') : open('rental') + open('fees') + open('later');
  return owing === 0 ? 'nothing_owing' : 'open';
}
