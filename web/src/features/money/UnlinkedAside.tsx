'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { dismissUnlinkedStripe } from '@/server/actions/card-tools';

// Put an unlinked Stripe payment aside with the reason (not a booking's payment), or back on the list (r35, 1081).
export function UnlinkedAside({ id, aside }: { id: string; aside: string | null }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  const [err, setErr] = useState('');
  const [pending, run] = useTransition();
  const go = (undo: boolean) => run(async () => {
    const r = await dismissUnlinkedStripe({ charge_id: id, note, undo });
    if (!r.ok) { setErr(r.message); return; }
    setOpen(false); setErr(''); router.refresh();
  });
  if (aside) return <span className="small muted">Put aside: {aside} <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => go(true)}>Back on the list</button></span>;
  if (!open) return <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(true)} data-testid="unlinked-aside">Not a booking</button>;
  return (
    <form className="row" onSubmit={(e) => { e.preventDefault(); go(false); }}>
      <label className="vh" htmlFor={`ua-${id}`}>Why it is not a booking&apos;s payment</label>
      <input className="input" id={`ua-${id}`} value={note} onChange={(e) => setNote(e.target.value)} placeholder="An owner's fee, a test" />
      <button className="btn btn--ghost btn--sm" type="submit" disabled={pending}>Put aside</button>
      {err && <span className="small" role="alert">{err}</span>}
    </form>
  );
}
