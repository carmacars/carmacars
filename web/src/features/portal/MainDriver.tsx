'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from '@/components/Link';
import { addMainDriver, confirmLicenceRead } from '@/server/actions/portal';
import { useAct } from './useAct';
import { DateInput } from '@/components/DateInput';

// The licence reader on the renter's side (release 31, D2; migration 0602).
//
// The main driver needs an Ontario licence: when the reader finds a licence from elsewhere on the main driver, that person
// stays on the booking as an additional driver and the renter sees this one plain screen. One button: add a main driver
// with an Ontario licence (their name, email, mobile and date of birth; their licence photos next, read the same way;
// their own link to accept and sign). Or the renter uploads their own Ontario licence instead.
export function MainDriverNeeded({ number, own }: { number: string; own: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [v, setV] = useState({ full_name: '', email: '', mobile: '', date_of_birth: '' });
  const a = useAct<{ driverId: string }>();
  const set = (k: keyof typeof v) => (e: React.ChangeEvent<HTMLInputElement>) => setV({ ...v, [k]: e.target.value });
  const field = (k: keyof typeof v, label: string, type = 'text', auto = 'off') => (
    <div className={`field${a.err(k) ? ' has-error' : ''}`}><label className="label" htmlFor={`md-${k}`}>{label}</label>
      {type === 'date' ? <DateInput className="input" id={`md-${k}`} type="date" value={v[k]} onChange={set(k)} aria-invalid={!!a.err(k) || undefined} aria-describedby={`md-${k}-err`} data-testid={`md-${k}`} />
        : <input className="input" id={`md-${k}`} type={type} value={v[k]} onChange={set(k)} autoComplete={auto} aria-invalid={!!a.err(k) || undefined} aria-describedby={`md-${k}-err`} data-testid={`md-${k}`} />}
      <p className="error" role="alert" id={`md-${k}-err`}>{a.err(k) ?? ''}</p></div>);
  return (
    <section className="pt-card pt-card--next stack" aria-labelledby="md-t" data-testid="main-driver-needed">
      <h2 className="d4" id="md-t">Main driver</h2>
      <p>The main driver needs an Ontario licence. Add a driver with an Ontario licence as the main driver. You&apos;ll stay on the booking as an extra driver.</p>
      {!open && <p><button className="btn btn--primary" type="button" onClick={() => setOpen(true)} data-testid="md-open">Add main driver</button></p>}
      {open && (
        <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => addMainDriver(number, v), (r) => { if (r.ok) router.refresh(); }); }} data-testid="md-form">
          {field('full_name', 'Full name, as on their licence', 'text', 'off')}
          <div className="field-row">{field('email', 'Email', 'email')}{field('mobile', 'Mobile', 'tel')}</div>
          {field('date_of_birth', 'Date of birth', 'date')}
          <p className="small muted">Next: a photo of the front and back of their licence. They get their own link to accept and sign.</p>
          {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
          <button className="btn btn--primary" type="submit" disabled={a.pending} data-testid="md-save">{a.pending ? 'Adding' : 'Add main driver'}</button>
        </form>)}
      <p className="small"><Link prefetch={false} className="link" href={own} data-testid="md-own">I have an Ontario licence: upload it instead</Link></p>
    </section>
  );
}

export interface ReadDriver { driver_id: string; role: string; name: string; licence_number: string | null; licence_class: string | null; licence_issuer: string | null; licence_expiry: string | null; read: boolean; confirmed_at: string | null }

/** What the reader filled in from the photo, for the renter to confirm (or change on the form below). */
export function LicenceReadConfirm({ number, d, onChange }: { number: string; d: ReadDriver; onChange?: string }) {
  const router = useRouter();
  const a = useAct();
  return (
    <section className="pt-card stack" aria-labelledby={`lr-${d.driver_id}`} data-testid="licence-read-confirm">
      <h2 className="d4" id={`lr-${d.driver_id}`}>{d.role === 'renter' ? 'Your licence details' : `${d.name}'s licence details`}</h2>
      <p className="small">We read these from the licence photo. Check them.</p>
      <dl className="pt-dl">
        {([['Number', d.licence_number], ['Class', d.licence_class], ['Issued by', d.licence_issuer], ['Expiry', d.licence_expiry]] as const).map(([k, x]) => <div key={k}><dt>{k}</dt><dd>{x ?? 'Not read'}</dd></div>)}
      </dl>
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      <div className="row">
        <button className="btn btn--primary btn--sm" type="button" disabled={a.pending} onClick={() => a.run(() => confirmLicenceRead(number, d.driver_id), (r) => { if (r.ok) router.refresh(); })} data-testid="lr-confirm">These are right</button>
        {onChange && <Link prefetch={false} className="btn btn--ghost btn--sm" href={onChange} data-testid="lr-change">Change them</Link>}
      </div>
    </section>
  );
}
