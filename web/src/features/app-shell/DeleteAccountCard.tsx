'use client';
import { useState, useTransition } from 'react';
import { requestAccountDeletion, withdrawAccountDeletion } from '@/server/actions/account-deletion';
import { deletionStep, type DeletionState } from './deletion';

// Delete my account (migration 0390): on the renter's, owner's and investor's profile, in the app and on the site
// (Apple requires that an app with sign-up lets people start deleting their account inside it). Two steps: the
// button, then a confirmation with an optional reason. The Admin finishes it within 30 days and replies.
const fmt = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'America/Toronto' });

export function DeleteAccountCard({ initial, className = 'pt-card' }: { initial: DeletionState; className?: string }) {
  const [state, setState] = useState(initial);
  const [confirming, setConfirming] = useState(false);
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const step = deletionStep(state);
  if (step === 'hidden') return null;

  const ask = () => start(async () => {
    setError(null);
    const r = await requestAccountDeletion(reason);
    if (!r.ok) { setError(r.message); return; }
    setState(r.data); setConfirming(false);
  });
  const withdraw = () => start(async () => {
    setError(null);
    const r = await withdrawAccountDeletion();
    if (!r.ok) { setError(r.message); return; }
    setState(r.data);
  });

  return (
    <section className={`${className} stack`} aria-labelledby="del-title" data-testid="delete-account">
      <h2 className="d4" id="del-title">Delete my account</h2>
      {step === 'asked' && state.request && (
        <>
          <p className="small" data-testid="delete-asked">You asked us to delete your account on {fmt(state.request.requested_at)}. We settle anything still open (a rental, a deposit, a payout), delete your account and email you within 30 days.</p>
          <div className="row"><button type="button" className="btn btn--ghost btn--sm" onClick={withdraw} disabled={pending} data-testid="delete-withdraw">Keep my account</button></div>
        </>
      )}
      {step === 'done' && <p className="small">Your earlier request was completed.</p>}
      {step === 'ask' && !confirming && (
        <>
          <p className="small muted">Close your account and delete your personal details: profile, licence and selfie photos, saved choices and alerts. We keep rental agreements, receipts and tax records as the law requires.</p>
          <div className="row"><button type="button" className="btn btn--ghost btn--sm" onClick={() => setConfirming(true)} data-testid="delete-start">Delete my account</button></div>
        </>
      )}
      {step === 'ask' && confirming && (
        <div className="stack" data-testid="delete-confirm">
          <p className="small"><b>Delete your account?</b> You can no longer sign in once it is done. Anything still open (a rental, a deposit, money owed either way) is settled first.</p>
          <div className="field">
            <label className="label" htmlFor="del-reason">Anything we should know? (optional)</label>
            <textarea id="del-reason" className="input" rows={2} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
          </div>
          <div className="row">
            <button type="button" className="btn btn--primary btn--sm" onClick={ask} disabled={pending} data-testid="delete-confirm-btn">{pending ? 'Sending…' : 'Yes, delete my account'}</button>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => setConfirming(false)} disabled={pending}>Cancel</button>
          </div>
        </div>
      )}
      {error && <p className="alert alert--error" role="alert"><span>{error}</span></p>}
    </section>
  );
}
