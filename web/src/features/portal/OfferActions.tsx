'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { approveOffer, declineOffer, requestOfferChange } from '@/server/actions/portal';
import { useAct } from './useAct';

const REASONS = ['I found another car', 'The price', 'My dates changed', 'Other'];

// Approve and continue, Ask for a change (sheet with a required note), Decline (with a reason).
export function OfferActions({ number, version }: { number: string; version: number }) {
  const router = useRouter();
  const [open, setOpen] = useState<'' | 'change' | 'decline'>('');
  const approve = useAct();
  const change = useAct();
  const decline = useAct();
  const [note, setNote] = useState('');
  const [reason, setReason] = useState(REASONS[0]!);
  const done = (r: { ok: boolean }) => { if (r.ok) router.refresh(); };
  return (
    <div className="pt-actions">
      {approve.res && !approve.res.ok && <p className="alert alert--error" role="alert"><span className="alert__title">{approve.res.code === 'stale' ? 'Offer updated' : 'Not approved'}</span><span>{approve.res.message}</span></p>}
      <button type="button" className="btn btn--primary btn--lg" disabled={approve.pending} onClick={() => approve.run(() => approveOffer(number, version), (r) => { if (!r.ok) router.refresh(); })}>
        {approve.pending ? 'Preparing your agreement' : 'Approve and continue'}
      </button>
      <button type="button" className="btn btn--ghost" aria-expanded={open === 'change'} aria-controls="pt-change" onClick={() => setOpen(open === 'change' ? '' : 'change')}>Ask for a change</button>
      <div className="pt-sheet" id="pt-change" hidden={open !== 'change'}>
        {change.res?.ok ? <p role="status">Sent. We will look at it and send you a new offer.</p> : (
          <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); change.run(() => requestOfferChange(number, note), done); }}>
            <div className={`field${change.err('note') ? ' has-error' : ''}`}>
              <label className="label" htmlFor="pt-change-note">What should we change?</label>
              <textarea className="textarea" id="pt-change-note" value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} aria-invalid={!!change.err('note') || undefined} aria-describedby="pt-change-hint pt-change-err" />
              <p className="hint" id="pt-change-hint">10 to 500 characters. For example, other dates or another car.</p>
              <p className="error" role="alert" id="pt-change-err">{change.err('note') ?? (change.res && !change.res.ok ? change.res.message : '')}</p>
            </div>
            <button className="btn btn--primary" type="submit" disabled={change.pending}>{change.pending ? 'Sending' : 'Send request'}</button>
          </form>
        )}
      </div>
      <button type="button" className="btn btn--quiet" aria-expanded={open === 'decline'} aria-controls="pt-decline" onClick={() => setOpen(open === 'decline' ? '' : 'decline')}>Decline offer</button>
      <div className="pt-sheet" id="pt-decline" hidden={open !== 'decline'}>
        <form className="stack" onSubmit={(e) => { e.preventDefault(); decline.run(() => declineOffer(number, reason), done); }}>
          <div className="field">
            <label className="label" htmlFor="pt-decline-why">Why are you declining?</label>
            <select className="select" id="pt-decline-why" value={reason} onChange={(e) => setReason(e.target.value)}>{REASONS.map((r) => <option key={r}>{r}</option>)}</select>
          </div>
          {decline.res && !decline.res.ok && <p className="error" role="alert">{decline.res.message}</p>}
          <button className="btn btn--primary" type="submit" disabled={decline.pending}>{decline.pending ? 'Declining' : 'Decline this offer'}</button>
        </form>
      </div>
    </div>
  );
}
