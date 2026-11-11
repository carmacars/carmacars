'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from './useAct';
import { saveSecondaryContact } from '@/server/actions/renter-extras';

// r35a (1302): an optional second person we call when we cannot reach the renter: a name, how they are related, and a
// phone and/or an email. On the profile (every booking) or on one booking (this trip only). An empty name removes it.
export interface ContactValue { name: string; relationship: string; phone: string | null; email: string | null }

export function SecondaryContactForm({ initial, booking, testId = 'secondary-contact-form' }: { initial: ContactValue | null; booking?: string; testId?: string }) {
  const [f, setF] = useState({ name: initial?.name ?? '', relationship: initial?.relationship ?? '', phone: initial?.phone ?? '', email: initial?.email ?? '' });
  const [scope, setScope] = useState<'profile' | 'booking' | 'both'>(booking ? 'booking' : 'profile');
  const a = useAct();
  const router = useRouter();
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => { a.setRes(null); setF((x) => ({ ...x, [k]: e.target.value })); };
  const id = (k: string) => `sc-${booking ? 'b' : 'p'}-${k}`;
  return (
    <form className="stack" data-testid={testId} onSubmit={(e) => { e.preventDefault(); if (a.pending) return; a.run(() => saveSecondaryContact({ ...f, scope, booking }), (r) => { if (r.ok) router.refresh(); }); }}>
      <div className="field"><label className="label" htmlFor={id('name')}>Name</label><input className="input" id={id('name')} value={f.name} maxLength={120} onChange={set('name')} autoComplete="off" /></div>
      <div className="field"><label className="label" htmlFor={id('rel')}>How they are related to you</label><input className="input" id={id('rel')} value={f.relationship} maxLength={60} placeholder="Spouse, parent, friend" onChange={set('relationship')} /></div>
      <div className="field"><label className="label" htmlFor={id('phone')}>Phone</label><input className="input" id={id('phone')} type="tel" inputMode="tel" value={f.phone} onChange={set('phone')} /></div>
      <div className="field"><label className="label" htmlFor={id('email')}>Email</label><input className="input" id={id('email')} type="email" inputMode="email" value={f.email} onChange={set('email')} />
        <p className="hint">A phone, an email or both. Leave the name empty to remove the contact.</p></div>
      {booking && <fieldset className="field" style={{ border: 0, padding: 0, margin: 0 }}><legend className="label">Use it for</legend>
        <label className="check"><input type="radio" name={id('scope')} checked={scope === 'booking'} onChange={() => setScope('booking')} /> <span>This trip only</span></label>
        <label className="check"><input type="radio" name={id('scope')} checked={scope === 'both'} onChange={() => setScope('both')} /> <span>This trip and my profile</span></label></fieldset>}
      {a.res && !a.res.ok && <p className="alert alert--warn" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>Saved.</span></p>}
      <p><button className="btn btn--ghost btn--sm" type="submit" disabled={a.pending} data-testid={`${testId}-save`}>{a.pending ? 'Saving' : 'Save the contact'}</button></p>
    </form>
  );
}
