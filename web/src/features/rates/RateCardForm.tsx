'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { rateSave } from '@/server/actions/rates';
import { RateFields, rateValuesFrom } from './RateFields';
import { ratePayload, type RateCheck } from './rates';

// A car's rates and kilometre terms, saved in one step (migration 0064): Admin > Vehicles > the car > Rates, and the
// Fleet assistant's car page. A new rate card starts at the time chosen; bookings already made keep their rates.
export function RateCardForm({ vehicleId, card, refresh, testId = 'rate-form' }: { vehicleId: string; card: Record<string, unknown> | null; refresh: string[]; testId?: string }) {
  const router = useRouter();
  const [v, setV] = useState(() => rateValuesFrom(card));
  const [from, setFrom] = useState('');
  const [chk, setChk] = useState<RateCheck | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const set = (k: string, value: string) => { setV((s) => ({ ...s, [k]: value })); setMsg(null); };
  const submit = () => start(async () => {
    setMsg(null);
    if (chk && !chk.ok) { setMsg({ ok: false, text: `Check the highlighted fields: ${chk.messages.join(' ')}` }); return; }
    const r = await rateSave({ vehicle: vehicleId, ...ratePayload(v, { delivery: true }), effective_from: from ? new Date(from).toISOString() : undefined }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: 'New rates saved.' });
    router.refresh();
  });
  return (
    <form className="ad-form stack" noValidate data-testid={`${testId}-form`} onSubmit={(e) => { e.preventDefault(); submit(); }}>
      {!card && <p className="alert" role="note" data-testid={`${testId}-none`}><span>No rates yet. Type the daily rate (the others can follow from it) and keep the default kilometres, or set your own. Everything saves together.</span></p>}
      <RateFields v={v} set={set} context={{ vehicle: vehicleId }} prefix={testId} delivery onCheck={setChk} />
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor={`${testId}-from`}>Effective from (empty: now)</label>
          <input className="input" id={`${testId}-from`} type="datetime-local" value={from} onChange={(e) => setFrom(e.target.value)} data-testid={`${testId}-from`} /></div>
      </div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid={`${testId}-msg`}><span>{msg.text}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={pending} data-testid={`${testId}-submit`}>{pending ? 'Saving' : 'Save the rates'}</button></div>
    </form>
  );
}
