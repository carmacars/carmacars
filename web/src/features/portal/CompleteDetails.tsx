'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { completeAgreementDetails } from '@/server/actions/portal';
import { AddressFields } from '@/features/forms/AddressFields';
import { InsurerSelect } from '@/features/insurers/InsurerSelect';
import { checkDetails, detailFields, detailPayload, type RenterMissing } from './renter-details';
import { useAct } from './useAct';

const PROVINCES: [string, string][] = [['ON', 'Ontario'], ['QC', 'Quebec'], ['BC', 'British Columbia'], ['AB', 'Alberta'], ['MB', 'Manitoba'], ['SK', 'Saskatchewan'], ['NS', 'Nova Scotia'], ['NB', 'New Brunswick'], ['NL', 'Newfoundland and Labrador'], ['PE', 'Prince Edward Island'], ['YT', 'Yukon'], ['NT', 'Northwest Territories'], ['NU', 'Nunavut']];

// "Complete your details" (migration 0195): the blanks of the rental agreement the renter fills in, exactly those,
// before signing or paying and at the top of the booking. Saved once; the agreement follows.
export function CompleteDetails({ number, missing, then }: { number: string; missing: RenterMissing[];
  /** what comes after: "sign" or "pay" (the line under the title) */
  then?: 'sign' | 'pay' }) {
  const router = useRouter();
  const a = useAct<{ missing: unknown[] }>();
  const fields = detailFields(missing);
  const [v, setV] = useState<Record<string, string>>({ province: 'ON', country: 'Canada', licence_issuer: 'ON' });
  const [errs, setErrs] = useState<Record<string, string>>({});
  if (!fields.length) return null;
  const err = (k: string) => errs[k] ?? a.err(k);
  const set = (k: string) => (e: { target: { value: string } }) => setV((s) => ({ ...s, [k]: e.target.value }));
  const submit = () => {
    const vals = v.licence_issuer === 'OTHER' ? { ...v, licence_issuer: v.licence_country ?? '' } : v;
    const e = checkDetails(fields, vals);
    setErrs(e);
    if (Object.keys(e).length) return;
    a.run(() => completeAgreementDetails(number, detailPayload(fields, vals)), (r) => { if (r.ok) router.refresh(); });
  };
  return (
    <section className="pu-panel pu-panel--next" aria-labelledby="pt-complete" data-testid="complete-details">
      <h2 className="pu-title" id="pt-complete">Complete your details</h2>
      <p>Your rental agreement needs {fields.length === 1 ? 'this' : 'these'} before you {then === 'pay' ? 'pay' : then === 'sign' ? 'sign' : 'sign or pay'}. Add {fields.length === 1 ? 'it' : 'them'} once; the agreement then shows {fields.length === 1 ? 'it' : 'them'}.</p>
      <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }} aria-label="Complete your details">
        {fields.map((f) => {
          const id = `pt-cd-${f.name}`;
          if (f.input === 'address') return <AddressFields key={f.name} idp="pt-cd" value={v} onChange={(p) => setV((s) => ({ ...s, ...p }))} streetLabel="Home address" lookupLabel="Find your home address"
            errors={{ address_line1: err('address_line1'), city: err('city'), province: err('province'), postal_code: err('postal_code'), country: err('country') }} />;
          return (
            <div key={f.name} className={`field${err(f.name) ? ' has-error' : ''}`}>
              <label className="label" htmlFor={id}>{f.label}</label>
              {f.input === 'insurer' ? <InsurerSelect id={id} value={v[f.name] ?? ''} onChange={(x) => setV((s) => ({ ...s, [f.name]: x }))} required testId="complete-insurer" />
                : f.input === 'issuer' ? <select className="select" id={id} value={v[f.name] ?? ''} onChange={set(f.name)}>{PROVINCES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}<option value="OTHER">Another country</option></select>
                : <input className="input" id={id} type={f.input === 'date' ? 'date' : f.input === 'tel' ? 'tel' : 'text'} inputMode={f.input === 'last4' ? 'numeric' : undefined} maxLength={f.input === 'last4' ? 4 : undefined}
                    autoComplete={f.name === 'date_of_birth' ? 'bday' : f.input === 'tel' ? 'tel' : 'off'} value={v[f.name] ?? ''} onChange={set(f.name)} aria-invalid={!!err(f.name) || undefined}
                    aria-describedby={`${f.hint ? `${id}-hint ` : ''}${id}-err`} data-testid={`complete-${f.name}`} />}
              {f.name === 'licence_issuer' && v.licence_issuer === 'OTHER' && <input className="input" aria-label="Country that issued the licence" placeholder="Country that issued the licence" value={v.licence_country ?? ''}
                onChange={(e) => setV((s) => ({ ...s, licence_country: e.target.value }))} style={{ marginTop: 'var(--s-2)' }} />}
              {f.hint && <p className="hint" id={`${id}-hint`}>{f.hint}</p>}
              <p className="error" role="alert" id={`${id}-err`}>{err(f.name) ?? ''}</p>
            </div>
          );
        })}
        {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
        <button className="btn btn--primary" type="submit" disabled={a.pending} data-testid="complete-details-save">{a.pending ? 'Saving' : 'Save my details'}</button>
      </form>
    </section>
  );
}
