'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { startCardRequest } from '@/server/actions/offers';

// At the check-out (0129 with 0130): field staff collect the deposit on their phone, handed to the renter, who types the
// card in Stripe's form on the pay page. Field staff take no payment themselves (Field Staff Agreement 6.1): never cash,
// never a card number typed by staff. A rental longer than the hold limit saves the card instead; Finance charges the
// deposit to it.
export function FieldCollect({ booking, jobId, deposit, longRental }: { booking: string; jobId: string; deposit: 'taken' | 'waived' | 'declined' | 'not_taken' | 'none'; longRental: boolean }) {
  const router = useRouter();
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, run] = useTransition();
  if (deposit === 'taken' || deposit === 'waived' || deposit === 'none') return null;
  const go = (kind: 'hold' | 'setup') => run(async () => {
    setMsg(null);
    const r = await startCardRequest({ booking, kind, channel: 'device', back: `/field/jobs/${jobId}` });
    if (!r.ok) { setMsg(r.message); return; }
    router.push(r.data.url);
  });
  return (
    <section className="fd-card stack" aria-labelledby="fc-t" data-testid="field-collect">
      <h2 className="d4" id="fc-t">Deposit</h2>
      <p className="small">{deposit === 'declined' ? 'The deposit was declined. Ask the renter for another credit card in their name.' : 'The deposit is not taken yet.'} Hand this phone to the renter: they type their card in Stripe&apos;s secure form. You never type a card number or take cash.</p>
      {longRental
        ? <button className="btn btn--primary fd-wide" type="button" disabled={pending} onClick={() => go('setup')} data-testid="field-save-card">{pending ? 'Opening' : 'Save the card (long rental)'}</button>
        : <button className="btn btn--primary fd-wide" type="button" disabled={pending} onClick={() => go('hold')} data-testid="field-deposit-hold">{pending ? 'Opening' : 'Place the deposit hold on this phone'}</button>}
      {longRental && <p className="small muted">A rental longer than the hold limit takes no hold: Finance charges the deposit to the saved card.</p>}
      {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
    </section>
  );
}
