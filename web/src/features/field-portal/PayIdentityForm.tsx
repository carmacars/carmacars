'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { payIdentitySave, type PayIdentity } from '@/server/actions/field-work';
import { FdIcon } from '@/features/field/icons';
import { PhotoPick } from './Steps';
import { validSin } from './model';

// My pay > Pay details (r35 part X, 0931): the step before the first pay. The SIN is checked here, encrypted on the server and never
// shown again: only its last 3 digits. The void cheque is a private file. Finance and Admin alone can open either, and each view is logged.
export function PayIdentityForm({ v }: { v: PayIdentity }) {
  const router = useRouter();
  const [open, setOpen] = useState(!v.complete);
  const [f, setF] = useState({ legal_name: v.legal_name ?? '', email: v.email ?? '', phone: v.phone ?? '', sin: '' });
  const [cheque, setCheque] = useState<File | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [ok, setOk] = useState(false);
  const [pending, start] = useTransition();
  const set = (k: keyof typeof f, x: string) => setF((s) => ({ ...s, [k]: x }));
  const save = () => start(async () => {
    setErr(null); setOk(false);
    if (f.sin && !validSin(f.sin)) { setErr('Check the SIN: 9 digits, as on your SIN letter.'); return; }
    const fd = new FormData();
    for (const [k, x] of Object.entries(f)) fd.set(k, x);
    if (cheque) fd.set('cheque', cheque);
    const r = await payIdentitySave(fd);
    if (!r.ok) { setErr(r.message); return; }
    setOk(true); set('sin', ''); setCheque(null);
    if (r.data.complete) setOpen(false);
    router.refresh();
  });
  return (
    <section className={`fp-paystep${v.complete ? ' is-done' : ''}`} id="pay-details" aria-labelledby="pid-h" data-testid="pay-identity">
      <h2 className="fd-section-h" id="pid-h">{v.complete ? 'Pay details: done' : 'Pay details: needed before you are paid'}</h2>
      {v.complete ? <p className="fp-done"><FdIcon name="check" />{v.legal_name}, SIN {v.sin}, void cheque on file.</p>
        : <p className="small">Still needed: {v.missing.join(', ')}.</p>}
      {!open ? <button type="button" className="btn btn--ghost fd-wide" onClick={() => setOpen(true)} data-testid="pid-change">Change my pay details</button> : <div className="fp-form">
        <div className="field"><label className="label" htmlFor="pid-name">Full legal name (as on your SIN letter)</label><input id="pid-name" className="input" autoComplete="name" value={f.legal_name} onChange={(e) => set('legal_name', e.target.value)} data-testid="pid-name" /></div>
        <div className="field"><label className="label" htmlFor="pid-email">Email</label><input id="pid-email" className="input" type="email" autoComplete="email" value={f.email} onChange={(e) => set('email', e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor="pid-phone">Phone</label><input id="pid-phone" className="input" type="tel" autoComplete="tel" value={f.phone} onChange={(e) => set('phone', e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor="pid-sin">SIN {v.sin ? `(on file: ${v.sin}; type it only to change it)` : ''}</label>
          <input id="pid-sin" className="input fd-num" inputMode="numeric" autoComplete="off" value={f.sin} maxLength={11} onChange={(e) => set('sin', e.target.value.replace(/[^\d -]/g, ''))} data-testid="pid-sin" />
          <span className="small">Kept encrypted. Only Finance and Admin can see it, and every look is recorded.</span></div>
        <PhotoPick file={cheque} set={setCheque} pdf label={v.cheque ? 'Void cheque on file: tap to replace' : 'Photo of a void cheque'} testId="pid-cheque" />
        <button type="button" className="btn btn--primary fd-wide" disabled={pending} onClick={save} data-testid="pid-save">{pending ? 'Saving' : 'Save my pay details'}</button>
        {err && <p className="error" role="alert">{err}</p>}
        {ok && <p className="fp-done" role="status"><FdIcon name="check" />Saved.</p>}
      </div>}
    </section>
  );
}
