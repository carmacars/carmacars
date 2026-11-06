'use client';
import { useState, useTransition } from 'react';
import { askReopenOffer } from '@/server/actions/reopen-ask';
import { ASK_REOPEN_DONE } from '@/features/offers/pickup-passed';
import { DateInput } from '@/components/DateInput';

// "Ask to reopen this offer" (0569): one tap on an expired offer, with a new pickup time if wanted.
export function AskReopen({ number }: { number: string }) {
  const [pickup, setPickup] = useState('');
  const [done, setDone] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  if (done) return <p className="alert alert--ok" role="status" data-testid="ask-reopen-done"><span>{ASK_REOPEN_DONE}</span></p>;
  return (
    <form className="stack" data-testid="ask-reopen" onSubmit={(e) => { e.preventDefault(); start(async () => {
      setErr(null);
      const r = await askReopenOffer(number, pickup ? new Date(pickup).toISOString() : null);
      if (r.ok) setDone(true); else setErr(r.message);
    }); }}>
      <div className="field"><label className="label" htmlFor={`ask-reopen-${number}`}>New pickup time (optional)</label>
        <DateInput className="input" id={`ask-reopen-${number}`} type="datetime-local" value={pickup} onChange={(e) => setPickup(e.target.value)} /></div>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <p><button className="btn btn--primary" type="submit" disabled={pending} data-testid="ask-reopen-send">{pending ? 'Sending' : 'Ask to reopen this offer'}</button></p>
    </form>
  );
}
