// 0261: where the automatic deposit hold of the pickup day is, in words (the Money tab and the handover ready check).
export interface DepositAuto { status: 'off' | 'scheduled' | 'no_card' | 'running' | 'held' | 'failed'; due_at?: string | null; at?: string | null; error?: string | null; amount_cents?: number | null }

export function depositAutoText(a: DepositAuto | null | undefined, when: (iso: string) => string, money: (cents: number) => string): string | null {
  if (!a || a.status === 'off') return null;
  const amt = a.amount_cents ? ` of ${money(a.amount_cents)}` : '';
  switch (a.status) {
    case 'scheduled': return `Deposit hold${amt} placed automatically on the card on file${a.due_at ? ` ${when(a.due_at)}` : ' on the pickup day'}.`;
    case 'no_card': return `No usable card on file for the automatic deposit hold: the renter gets the deposit link; take it at the handover if still missing.`;
    case 'running': return `Deposit hold${amt} being placed on the card on file.`;
    case 'held': return `Deposit hold${amt} placed automatically on the card on file${a.at ? ` ${when(a.at)}` : ''}.`;
    case 'failed': return `Deposit not taken: the automatic hold did not go through (${a.error ?? 'declined'}). The renter was sent the deposit link; take it now if it is still missing.`;
  }
  return null;
}
