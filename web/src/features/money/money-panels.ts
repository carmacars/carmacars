// The booking's Money tab in two panels (release 29, C0): Rental charges and Security deposit, kept apart. Pure: the
// panels and the unit tests share it (money-panels.test.ts).
export type DepositWord = 'Not collected' | 'Held' | 'Charged' | 'Released' | 'Partly kept' | 'Waived' | 'No deposit';
export interface DepositRow { method: string; paid_method?: string | null; status: string; amount_cents: number; captured_cents?: number; released_cents?: number; applied_cents?: number; held_back_cents?: number }
export interface PayRow { purpose: string; kind: string; method: string; amount_cents: number; status: string; covers: string | null; voided?: boolean }

/** The deposit's status as one word. */
export function depositWord(d: DepositRow | null, depositCents: number, waived = false): DepositWord {
  if (waived) return 'Waived';
  if (!d || ['pending', 'failed'].includes(d.status)) return depositCents > 0 ? 'Not collected' : 'No deposit';
  if (d.status === 'held') return 'Held';
  const kept = Number(d.applied_cents ?? 0) + Number(d.held_back_cents ?? 0) + (d.method === 'card_hold' ? Number(d.captured_cents ?? 0) : 0);
  if (d.status === 'settled' || Number(d.released_cents ?? 0) > 0) return kept > 0 ? 'Partly kept' : 'Released';
  if (d.status === 'captured') return d.method === 'card_hold' ? 'Partly kept' : 'Charged';
  if (d.status === 'carried_forward') return 'Charged';
  return 'Not collected';
}

/** The deposit's next step, for the one primary button. */
export function depositNext(word: DepositWord, bookingStatus: string): 'collect' | 'settle' | 'held' | 'none' {
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
