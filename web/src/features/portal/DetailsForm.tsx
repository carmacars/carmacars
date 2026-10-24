'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { saveDetails, type DetailsInput } from '@/server/actions/portal';
import { useAct } from './useAct';
import { AddressFields } from '@/features/forms/AddressFields';

const PROVINCES: [string, string][] = [['ON', 'Ontario'], ['QC', 'Quebec'], ['BC', 'British Columbia'], ['AB', 'Alberta'], ['MB', 'Manitoba'], ['SK', 'Saskatchewan'], ['NS', 'Nova Scotia'], ['NB', 'New Brunswick'], ['NL', 'Newfoundland and Labrador'], ['PE', 'Prince Edward Island'], ['YT', 'Yukon'], ['NT', 'Northwest Territories'], ['NU', 'Nunavut']];

// Part A of the signing page: what the agreement needs that we do not hold yet (02 section 5).
export function DetailsForm({ number, initial }: { number: string; initial: Partial<DetailsInput> }) {
  const router = useRouter();
  const a = useAct();
  const [v, setV] = useState<DetailsInput>({ address_line1: '', address_line2: '', city: '', province: 'ON', postal_code: '', country: 'Canada', licence_number: '', licence_class: 'G', licence_issuer: 'ON', licence_expiry: '', ...Object.fromEntries(Object.entries(initial).filter(([, x]) => x)) } as DetailsInput);
  const other = !PROVINCES.some(([c]) => c === v.licence_issuer);
  const set = (k: keyof DetailsInput) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setV({ ...v, [k]: e.target.value });
  const f = (k: keyof DetailsInput, label: string, props: React.InputHTMLAttributes<HTMLInputElement> = {}, hint?: string) => (
    <div className={`field${a.err(k) ? ' has-error' : ''}`}>
      <label className="label" htmlFor={`pt-d-${k}`}>{label}</label>
      <input className="input" id={`pt-d-${k}`} value={v[k] ?? ''} onChange={set(k)} aria-invalid={!!a.err(k) || undefined} aria-describedby={`${hint ? `pt-d-${k}-hint ` : ''}pt-d-${k}-err`} {...props} />
      {hint && <p className="hint" id={`pt-d-${k}-hint`}>{hint}</p>}
      <p className="error" role="alert" id={`pt-d-${k}-err`}>{a.err(k) ?? ''}</p>
    </div>
  );
  return (
    <form className="stack-lg" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => saveDetails(number, v), (r) => { if (r.ok) router.refresh(); }); }} aria-label="Your details">
      <AddressFields idp="pt-d" value={v as unknown as Record<string, unknown>} onChange={(p) => setV((x) => ({ ...x, ...p }))} streetLabel="Home address" lookupLabel="Find your home address"
        errors={{ address_line1: a.err('address_line1'), city: a.err('city'), province: a.err('province'), postal_code: a.err('postal_code'), country: a.err('country') }} />
      <div className="field-row">
        <div className="field"><label className="label" htmlFor="pt-d-issuer">Licence issued by</label>
          <select className="select" id="pt-d-issuer" value={other ? 'OTHER' : v.licence_issuer} onChange={(e) => setV({ ...v, licence_issuer: e.target.value === 'OTHER' ? '' : e.target.value })}>
            {PROVINCES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}<option value="OTHER">Another country</option>
          </select></div>
        <div className="field"><label className="label" htmlFor="pt-d-class">Licence class</label>
          <select className="select" id="pt-d-class" value={v.licence_class} onChange={set('licence_class')}><option value="G">G (full)</option><option value="G2">G2</option><option value="OTHER">Another class</option></select></div>
      </div>
      {other && f('licence_issuer', 'Country that issued the licence')}
      {f('licence_number', 'Licence number', { autoComplete: 'off', autoCapitalize: 'characters', spellCheck: false }, v.licence_issuer === 'ON' ? 'As on the card, for example A1234-12345-12345.' : undefined)}
      {f('licence_expiry', 'Licence expiry', { type: 'date' }, 'It must be valid until the return date.')}
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>Saved. The agreement below now shows your details.</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Saving' : 'Save details'}</button>
    </form>
  );
}
