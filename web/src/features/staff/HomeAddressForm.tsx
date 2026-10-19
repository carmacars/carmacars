'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { saveHomeAddress } from '@/server/actions/home-address';

// The staff member's own home address (migration 0059): one form used at the first sign-in, in the staff agreement
// signing step, before Add a rental and in the profile.
export function HomeAddressForm({ portal, address, postal, button = 'Save my home address', testId = 'home-address-form' }: {
  portal: 'va' | 'field'; address?: string | null; postal?: string | null; button?: string; testId?: string }) {
  const router = useRouter();
  const id = useId().replace(/:/g, '');
  const [a, setA] = useState(address ?? '');
  const [p, setP] = useState(postal ?? '');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    setMsg(null);
    start(async () => {
      const r = await saveHomeAddress(portal, a, p);
      if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
      setMsg({ ok: true, text: 'Saved.' });
      router.refresh();
    });
  };
  return (
    <form className="stack" noValidate onSubmit={submit} data-testid={testId}>
      <div className="field"><label className="label" htmlFor={`${id}-a`}>Home address</label>
        <input className="input" id={`${id}-a`} name="home_address" autoComplete="street-address" value={a} onChange={(e) => setA(e.target.value)} aria-describedby={`${id}-ah`} data-testid="home-address" required />
        <p className="hint" id={`${id}-ah`}>Number, street, city and country, for example 12 Rizal Street, Quezon City, Philippines</p></div>
      <div className="field"><label className="label" htmlFor={`${id}-p`}>Postal code</label>
        <input className="input" id={`${id}-p`} name="home_postal_code" autoComplete="postal-code" value={p} onChange={(e) => setP(e.target.value)} style={{ maxWidth: '12rem' }} data-testid="home-postal" required /></div>
      {msg && <p className={msg.ok ? 'small' : 'alert alert--error'} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="home-address-save">{pending ? 'Saving' : button}</button></div>
    </form>
  );
}
