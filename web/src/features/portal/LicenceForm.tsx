'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { saveLicence } from '@/server/actions/portal';
import { useAct } from './useAct';

// The licence details (0130): number, who issued it, class and expiry. The expiry must be after the return.
export function LicenceForm({ number, initial }: { number: string; initial: { licence_number: string; licence_class: string; licence_issuer: string; licence_expiry: string } }) {
  const router = useRouter();
  const [v, setV] = useState(initial);
  const a = useAct();
  const set = (k: keyof typeof v) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setV({ ...v, [k]: e.target.value });
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => saveLicence(number, v), (r) => { if (r.ok) router.refresh(); }); }} data-testid="licence-form">
      <div className="field-row">
        <div className={`field${a.err('licence_number') ? ' has-error' : ''}`}><label className="label" htmlFor="lf-num">Licence number</label>
          <input className="input" id="lf-num" value={v.licence_number} onChange={set('licence_number')} autoComplete="off" aria-invalid={!!a.err('licence_number') || undefined} aria-describedby="lf-num-err" data-testid="lf-number" />
          <p className="error" role="alert" id="lf-num-err">{a.err('licence_number') ?? ''}</p></div>
        <div className="field"><label className="label" htmlFor="lf-iss">Issued by</label>
          <select className="select" id="lf-iss" value={v.licence_issuer} onChange={set('licence_issuer')}>
            {[['ON', 'Ontario'], ['QC', 'Quebec'], ['BC', 'British Columbia'], ['AB', 'Alberta'], ['MB', 'Manitoba'], ['SK', 'Saskatchewan'], ['NS', 'Nova Scotia'], ['NB', 'New Brunswick'], ['NL', 'Newfoundland and Labrador'], ['PE', 'Prince Edward Island'], ['US', 'United States'], ['OTHER', 'Another country']].map(([c, l]) => <option key={c} value={c}>{l}</option>)}
          </select></div>
      </div>
      <div className="field-row">
        <div className="field"><label className="label" htmlFor="lf-cls">Class</label><input className="input" id="lf-cls" value={v.licence_class} onChange={set('licence_class')} /></div>
        <div className={`field${a.err('licence_expiry') ? ' has-error' : ''}`}><label className="label" htmlFor="lf-exp">Expiry date</label>
          <input className="input" id="lf-exp" type="date" value={v.licence_expiry} onChange={set('licence_expiry')} aria-invalid={!!a.err('licence_expiry') || undefined} aria-describedby="lf-exp-err" data-testid="lf-expiry" />
          <p className="error" role="alert" id="lf-exp-err">{a.err('licence_expiry') ?? ''}</p></div>
      </div>
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>Saved.</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending} data-testid="lf-save">{a.pending ? 'Saving' : 'Save the licence details'}</button>
    </form>
  );
}
