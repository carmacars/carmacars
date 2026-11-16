'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { addTip } from '@/server/actions/tips';
import { pctLabel, tipChoiceCents, type TipOptions } from '@/features/money/tips';

// r48 part 2 (3053): the renter's tip: 10, 15 or 20% of the booking total, or an amount they type, paid by card on
// Stripe's own form. On the pay page (checkout), on the receipt after the return and on the after-trip link's page.
export function TipPicker({ number, options, source }: { number: string; options: TipOptions; source: 'checkout' | 'receipt' | 'link' }) {
  const router = useRouter();
  const [choice, setChoice] = useState(options.options[1] ? String(options.options[1].percent_bps) : 'custom');
  const [typed, setTyped] = useState('');
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, run] = useTransition();
  if (!options.on) return null;
  const cents = tipChoiceCents(options, choice, typed);
  const fmt = (c: number) => money(c, { cents: true });
  const why = cents === null ? (choice === 'custom' ? 'Type an amount of $1 or more first.' : 'Choose an amount first.') : '';
  const go = () => run(async () => {
    if (cents === null) return;
    const r = await addTip(number, cents, choice === 'custom' ? null : Number(choice), source);
    if (r.ok) router.push(r.data.url); else setMsg(r.message);
  });
  return (
    <section className="pt-card stack" aria-labelledby={`tip-h-${source}`} data-testid="tip-picker">
      <h2 className="d4" id={`tip-h-${source}`}>Add a tip for the team</h2>
      <p className="small">Optional. It goes to the people who looked after your rental: the person who booked it with you and the one who handed you the car.{options.paid_cents > 0 ? ` You have tipped ${fmt(options.paid_cents)}: thank you!` : ''}</p>
      <fieldset className="row" aria-label="Tip amount">
        {options.options.map((o) => (
          <label key={o.percent_bps} className="check" htmlFor={`tip-${source}-${o.percent_bps}`}>
            <input type="radio" name={`tip-${source}`} id={`tip-${source}-${o.percent_bps}`} checked={choice === String(o.percent_bps)} onChange={() => setChoice(String(o.percent_bps))} data-testid={`tip-${o.percent_bps}`} />
            <span>{pctLabel(o.percent_bps)} ({fmt(o.cents)})</span></label>))}
        <label className="check" htmlFor={`tip-${source}-custom`}>
          <input type="radio" name={`tip-${source}`} id={`tip-${source}-custom`} checked={choice === 'custom'} onChange={() => setChoice('custom')} data-testid="tip-custom" />
          <span>Another amount</span></label>
      </fieldset>
      {choice === 'custom' && <div className="field"><label className="label" htmlFor={`tip-${source}-amount`}>Amount ($)</label>
        <input className="input" id={`tip-${source}-amount`} inputMode="decimal" value={typed} onChange={(e) => setTyped(e.target.value)} data-testid="tip-amount" /></div>}
      <div className="row">
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || cents === null} aria-describedby={why ? `tip-why-${source}` : undefined} onClick={go} data-testid="tip-go">
          {pending ? 'Opening the card form' : cents !== null ? `Tip ${fmt(cents)} by card` : 'Tip by card'}</button>
        {why && <span className="hint" id={`tip-why-${source}`} data-testid="tip-why">{why}</span>}
      </div>
      {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
    </section>
  );
}
