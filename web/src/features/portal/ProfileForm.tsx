'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { saveProfile, type ProfileInput } from '@/server/actions/portal';
import { useAct } from './useAct';

export function ProfileForm({ initial }: { initial: ProfileInput }) {
  const router = useRouter();
  const a = useAct();
  const [v, setV] = useState<ProfileInput>(initial);
  const f = (k: keyof ProfileInput, label: string, props: React.InputHTMLAttributes<HTMLInputElement> = {}) => (
    <div className={`field${a.err(k) ? ' has-error' : ''}`}>
      <label className="label" htmlFor={`pt-p-${k}`}>{label}</label>
      <input className="input" id={`pt-p-${k}`} value={v[k] ?? ''} onChange={(e) => setV({ ...v, [k]: e.target.value })} aria-invalid={!!a.err(k) || undefined} aria-describedby={`pt-p-${k}-err`} {...props} />
      <p className="error" role="alert" id={`pt-p-${k}-err`}>{a.err(k) ?? ''}</p>
    </div>
  );
  return (
    <form className="stack-lg" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => saveProfile(v), (r) => { if (r.ok) router.refresh(); }); }} aria-label="Contact details">
      {f('mobile', 'Mobile', { type: 'tel', autoComplete: 'tel' })}
      {f('address_line1', 'Home address', { autoComplete: 'address-line1' })}
      {f('address_line2', 'Apartment or unit (optional)', { autoComplete: 'address-line2' })}
      <div className="field-row">{f('city', 'City', { autoComplete: 'address-level2' })}{f('province', 'Province or state', { autoComplete: 'address-level1' })}</div>
      <div className="field-row">{f('postal_code', 'Postal code', { autoComplete: 'postal-code' })}{f('country', 'Country', { autoComplete: 'country-name' })}</div>
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>Saved.</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Saving' : 'Save'}</button>
    </form>
  );
}
