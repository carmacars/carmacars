'use client';
import { useState } from 'react';
import { acceptChange, declineChangeProposal, retryChangePayment } from '@/server/actions/portal';
import { AMENDMENT_STATEMENT } from '@/features/agreement/amendment';
import { EsignFlow } from '@/features/signing/EsignFlow';
import type { EsignReady } from '@/features/signing/types';
import { useAct } from './useAct';

// Accept a change by signing the amendment (the signing session of 0143: the code, the payment term initialled, the
// consents, a drawn signature), or decline it. The extra amount, if any, is charged to
// the card on file when the amendment is signed; the booking changes only then.
export function ChangeAnswer({ number, requestId, stamp, legalName, payLine, signedUnpaid }: {
  number: string; requestId: string; stamp: string; legalName: string; payLine: string; signedUnpaid: boolean;
}) {
  const [agree, setAgree] = useState(false);
  const [sig, setSig] = useState<EsignReady | null>(null);
  const [local, setLocal] = useState<Record<string, string>>({});
  const [declining, setDeclining] = useState(false);
  const [reason, setReason] = useState('');
  const a = useAct<{ applied: boolean }>();
  const pay = useAct();
  const d = useAct();
  const err = (k: string) => local[k] ?? a.err(k);
  if (d.res?.ok) return <div className="pt-ok" role="status" data-testid="change-declined"><h2 className="d4">Change declined</h2><p>Your booking stays as it was. We let our team know.</p><p><a className="btn btn--primary" href={`/account/bookings/${encodeURIComponent(number)}`}>Back to the booking</a></p></div>;
  if (signedUnpaid) return (
    <div className="stack" data-testid="change-pay-again">
      <p>You signed the amendment, but the payment did not go through, so your booking has not changed yet. {payLine}</p>
      {pay.res && !pay.res.ok && <p className="alert alert--error" role="alert"><span>{pay.res.message}</span></p>}
      <button className="btn btn--primary" type="button" disabled={pay.pending} onClick={() => pay.run(() => retryChangePayment(number, requestId))} data-testid="change-pay">{pay.pending ? 'Paying' : 'Pay and apply the change'}</button>
    </div>
  );
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (!agree) fe.consents = 'Tick the statement to sign.';
    if (!sig) fe.signature = 'Finish the steps above: the code, the initials, the consents and your signature.';
    setLocal(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus()); return; }
    a.run(() => acceptChange(number, requestId, { agree, stamp, session: sig!.session, drawnPath: sig!.method === 'drawn' ? sig!.drawnPath : undefined, typedName: sig!.method === 'typed' ? sig!.typedName : undefined }));
  };
  return (
    <div className="stack-lg">
      <form className="stack-lg" noValidate onSubmit={submit} aria-label="Accept and sign the amendment">
        <p className="small">{payLine}</p>
        <fieldset className="pt-consents" aria-describedby="pt-amend-err" aria-invalid={!!err('consents') || undefined} tabIndex={-1}>
          <legend>Before you sign</legend>
          <label className="check"><input type="checkbox" checked={agree} onChange={(e) => { setAgree(e.target.checked); setLocal((l) => ({ ...l, consents: '' })); }} data-testid="amend-agree" /><span>{AMENDMENT_STATEMENT}</span></label>
          <p className="error" role="alert" id="pt-amend-err">{err('consents') ?? ''}</p>
        </fieldset>
        <div className={`field${err('signature') ? ' has-error' : ''}`}>
          <EsignFlow ctx={{ kind: 'amendment', number, requestId }} docsLabel="the amendment" onReady={(v) => { setSig(v); if (v) setLocal((l) => ({ ...l, signature: '' })); }}
            terms={[{ code: 'charges', title: 'The payment for this change', text: `${payLine} I authorize it on my card on file.` }]} />
          <span className="vh">{legalName}</span>
          <p className="error" role="alert" id="pt-amend-sig-err">{err('signature') ?? ''}</p>
        </div>
        {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert" data-testid="change-error"><span>{a.res.message}</span></p>}
        <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={a.pending} data-testid="change-accept">{a.pending ? 'Signing' : 'Accept and sign'}</button>
      </form>
      <div className="stack">
        {!declining ? <button className="btn btn--quiet" type="button" onClick={() => setDeclining(true)} data-testid="change-decline-open">Decline this change</button> : (
          <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); d.run(() => declineChangeProposal(number, requestId, reason)); }}>
            <div className="field"><label className="label" htmlFor="pt-decline-reason">Tell us why (optional)</label>
              <textarea className="input" id="pt-decline-reason" rows={3} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></div>
            {d.res && !d.res.ok && <p className="alert alert--error" role="alert"><span>{d.res.message}</span></p>}
            <div className="row"><button className="btn btn--primary" type="submit" disabled={d.pending} data-testid="change-decline">{d.pending ? 'Sending' : 'Decline the change'}</button>
              <button className="btn btn--quiet" type="button" onClick={() => setDeclining(false)}>Keep it open</button></div>
          </form>
        )}
      </div>
    </div>
  );
}
