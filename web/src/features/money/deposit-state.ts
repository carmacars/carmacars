// r48 part 2 (3052): the deposit for each way of paying it (app.deposit_state). A credit card hold is the deposit; e-Transfer
// and cash are the deposit times the Program setting (2x by default); a debit or prepaid card its own multiplier (0262).
// Pure: the Money tab, the renter's pay page and deposit-state.test.ts share it.
export interface DepositState {
  card_cents: number; offline_cents: number; debit_cents: number; offline_on: boolean; multiplier: number; set_by_staff: boolean;
  method: string | null; required_cents: number; taken_cents: number; owed_cents: number; over_cents: number;
}

/** What is still to take for a way of paying: that way's deposit less what is already taken (never below 0). */
export function depositDue(s: DepositState | null, fallbackCents: number): (method: string) => number {
  return (method) => {
    if (!s) return fallbackCents;
    const need = ['cash', 'e_transfer'].includes(method) ? s.offline_cents : ['debit', 'prepaid'].includes(method) ? s.debit_cents : s.card_cents;
    return Math.max(0, need - s.taken_cents);
  };
}

/** One line: the deposit by each way, when they differ ("Credit card hold $300.00; e-Transfer or cash $600.00 (2x)"). */
export function depositStateLine(s: DepositState | null, fmt: (c: number) => string): string | null {
  if (!s || s.offline_cents === s.card_cents) return null;
  return `Credit card hold ${fmt(s.card_cents)}; e-Transfer or cash ${fmt(s.offline_cents)}${s.set_by_staff ? ' (set for this booking)' : ` (${Number(s.multiplier)}x)`}`
    + (s.debit_cents !== s.card_cents && s.debit_cents !== s.offline_cents ? `; debit or prepaid card ${fmt(s.debit_cents)}` : '');
}

/** For the renter, before they pay: what each way costs, in one sentence. */
export function depositChoiceText(s: DepositState | null, fmt: (c: number) => string): string | null {
  if (!s || s.offline_cents === s.card_cents) return null;
  return `Your security deposit is ${fmt(s.card_cents)} held on a credit card, or ${fmt(s.offline_cents)} paid by e-Transfer, cash or debit (${s.set_by_staff ? 'set for this booking' : `${Number(s.multiplier)}x`}). It is given back after the trip, less anything owed.`;
}
