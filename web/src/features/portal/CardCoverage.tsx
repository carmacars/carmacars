'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { confirmCardCoverage, type CardCoverageState } from '@/server/actions/portal';

// Coverage option 2 (0070): the renter confirms the rental coverage of the credit card they pay with. Once the booking is
// paid with a credit card (not debit or prepaid) it is confirmed at once; the benefits certificate below is optional.
const STATE: Record<string, string> = {
  confirmed: 'Confirmed. Your card’s rental coverage is on file for this booking.',
  awaiting_payment: 'Thanks. It is confirmed as soon as you pay with this credit card.',
  not_credit: 'The card you paid with is not a credit card, so its coverage cannot be used. Call us to choose another coverage option.'
};

export function CardCoverage({ number, s }: { number: string; s: CardCoverageState }) {
  const router = useRouter();
  const [agree, setAgree] = useState(false);
  const [issuer, setIssuer] = useState('');
  const [msg, setMsg] = useState('');
  const [pending, start] = useTransition();
  const card = s.paid_card;
  if (s.confirmed) return <p className="pt-ok" data-testid="card-coverage-state">{STATE.confirmed}</p>;
  if (card && card.credit === false) return <p className="alert alert--error" role="alert" data-testid="card-coverage-state"><span>{STATE.not_credit}</span></p>;
  if (s.renter_confirmed) return <p className="small" data-testid="card-coverage-state">{STATE.awaiting_payment}</p>;
  return (
    <form className="stack" data-testid="card-coverage" onSubmit={(e) => { e.preventDefault(); start(async () => {
      const r = await confirmCardCoverage(number, issuer);
      setMsg(r.ok ? STATE[r.data.state] ?? 'Thanks.' : r.message);
      if (r.ok) router.refresh();
    }); }}>
      <p className="small">{card?.last4 ? `You paid with the ${card.brand ?? 'card'} ending ${card.last4}. ` : 'Pay with the same credit card. '}Debit and prepaid cards do not carry rental coverage.</p>
      <div className="field"><label className="label" htmlFor="pt-cc-issuer">Card issuer (optional)</label>
        <input className="input" id="pt-cc-issuer" value={issuer} onChange={(e) => setIssuer(e.target.value)} maxLength={60} placeholder="For example, American Express" /></div>
      <label className="check"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} data-testid="card-coverage-agree" /> <span>{s.wording}</span></label>
      <button className="btn btn--primary" type="submit" disabled={!agree || pending} data-testid="card-coverage-submit">{pending ? 'Saving' : 'Confirm my card’s coverage'}</button>
      {msg && <p className="small" role="status" data-testid="card-coverage-msg">{msg}</p>}
    </form>
  );
}
