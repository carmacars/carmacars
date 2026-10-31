// 0261: the deposit hold placed on the pickup day, off-session on the card on file. What Stripe's answer means for the
// try: the hold is authorized (record it), or it failed (record why, the renter gets the link and staff a task). Pure:
// the deposit job in deposit-guard.ts calls Stripe and the database around it.
export type AutoHoldStep = { next: 'settle' } | { next: 'failed'; reason: string; cancel: boolean };

/** The off-session authorization's status (or the error Stripe threw) to the next step. */
export function autoHoldStep(r: { status?: string | null; lastError?: string | null } | null, error?: unknown): AutoHoldStep {
  if (!r) {
    const m = error instanceof Error ? error.message : typeof error === 'string' ? error : '';
    const code = (error as { code?: string | null; declineCode?: string | null } | undefined)?.code ?? null;
    if (code === 'authentication_required' || /authenticat/i.test(m)) return { next: 'failed', reason: 'the bank wants the renter to approve the hold', cancel: false };
    return { next: 'failed', reason: m ? m.slice(0, 200) : 'Stripe could not be reached', cancel: false };
  }
  if (r.status === 'requires_capture' || r.status === 'succeeded') return { next: 'settle' };
  if (r.status === 'requires_action') return { next: 'failed', reason: 'the bank wants the renter to approve the hold', cancel: true };
  return { next: 'failed', reason: r.lastError || 'the card was declined', cancel: r.status !== 'canceled' && r.status !== 'requires_payment_method' };
}
