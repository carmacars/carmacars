'use client';
import { useState } from 'react';
import { savePayDetails } from '@/server/actions/staff-pay';
import { payMethodsFor, PAY_METHOD_LABEL, type PayDetailsInput, type PayDetailsView, type PayMethod } from '@/features/staff/pay-details';

// Profile > Pay details (release 33, migration 0730): how the staff member wants to be paid. The account number is never
// shown again after it is saved: only its last 4 digits. An Admin verifies new details with them.
export function PayDetails({ portal, view, canada = portal === 'field' }: { portal: 'va' | 'field'; view: PayDetailsView | null; canada?: boolean }) {
  const [cur, setCur] = useState(view?.current ?? null);
  const [open, setOpen] = useState(!view?.current);
  const [f, setF] = useState<PayDetailsInput>({ method: portal === 'field' ? 'e_transfer' : 'bank_transfer', account_holder: '' });
  const [fe, setFe] = useState<Record<string, string>>({});
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: keyof PayDetailsInput, v: string) => setF((x) => ({ ...x, [k]: v }));
  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setErr(null); setFe({});
    const r = await savePayDetails(portal, f);
    setBusy(false);
    if (!r.ok) { setErr(r.message); setFe(r.fieldErrors ?? {}); return; }
    setCur(r.data.current); setOpen(false); setF({ method: f.method, account_holder: '' });
  };
  const input = (k: keyof PayDetailsInput, label: string, extra: React.InputHTMLAttributes<HTMLInputElement> = {}) => (
    <div className="field"><label className="label" htmlFor={`pay-${k}`}>{label}</label>
      <input className="input" id={`pay-${k}`} value={(f[k] as string) ?? ''} onChange={(e) => set(k, e.target.value)} aria-invalid={!!fe[k]} {...extra} data-testid={`pay-${k}`} />
      {fe[k] && <span className="error">{fe[k]}</span>}</div>
  );
  return (
    <section className="pt-card stack" aria-labelledby="pay-t" id="pay" data-testid="pay-details">
      <h2 className="d4" id="pay-t">Pay details</h2>
      {cur ? <p className="small" data-testid="pay-current">{cur.shown}, in the name of {cur.account_holder}. {cur.verified ? 'Verified.' : 'An Admin will confirm them with you.'}</p>
        : <p className="small">How you want to be paid. Only the last 4 digits of an account number are ever shown again.</p>}
      {!open ? <p><button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)} data-testid="pay-change">Change my pay details</button></p> : (
        <form className="stack" noValidate onSubmit={save} aria-label="Pay details">
          <div className="field"><label className="label" htmlFor="pay-method">How you are paid</label>
            <select className="select" id="pay-method" value={f.method} onChange={(e) => set('method', e.target.value as PayMethod)} data-testid="pay-method">
              {payMethodsFor(canada, cur?.method).map((m) => <option key={m} value={m}>{m === 'bank_transfer' && canada ? 'Direct deposit (Canadian bank account)' : PAY_METHOD_LABEL[m]}</option>)}</select></div>
          {input('account_holder', 'Account holder (your name as the bank has it)', { autoComplete: 'name' })}
          {f.method === 'bank_transfer' && <>
            {input('bank_name', 'Bank')}
            {input('country', 'Country of the bank (optional)', { autoComplete: 'country-name' })}
            {input('account_no', 'Account number', { inputMode: 'numeric', autoComplete: 'off' })}
            {portal === 'field' && input('institution_no', 'Institution number (3 digits, optional)', { inputMode: 'numeric' })}
            {portal === 'field' && input('transit_no', 'Transit number (5 digits, optional)', { inputMode: 'numeric' })}
          </>}
          {f.method === 'gcash' && input('account_no', 'GCash mobile number', { inputMode: 'tel', autoComplete: 'off' })}
          {(f.method === 'e_transfer' || f.method === 'paypal' || f.method === 'wise') && input('email', 'Email address for the payment', { type: 'email', autoComplete: 'email' })}
          <p className="row"><button type="submit" className="btn btn--primary btn--sm" disabled={busy} data-testid="pay-save">{busy ? 'Saving' : 'Save my pay details'}</button>
            {cur && <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(false)}>Cancel</button>}</p>
          {err && <p className="error" role="alert">{err}</p>}
        </form>)}
    </section>
  );
}
