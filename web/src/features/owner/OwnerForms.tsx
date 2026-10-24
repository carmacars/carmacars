'use client';
import { useState } from 'react';
import { AddressFields } from '@/features/forms/AddressFields';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useAct } from '@/features/portal/useAct';
import { bookOwnCar, giveExitNotice, saveOwnerProfile, submitPayoutAccount, type OwnerProfileInput, type PayoutInput } from '@/server/actions/owner';

// Small owner forms: exit notice, payout details, contact details, booking my own car.
function Input({ id, label, value, set, err, hint, ...props }: { id: string; label: string; value: string; set: (v: string) => void; err?: string; hint?: string } & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'value'>) {
  return (
    <div className={`field${err ? ' has-error' : ''}`}>
      <label className="label" htmlFor={id}>{label}</label>
      <input className="input" id={id} value={value} onChange={(e) => set(e.target.value)} aria-invalid={!!err || undefined} aria-describedby={[hint ? `${id}-hint` : '', `${id}-err`].filter(Boolean).join(' ')} {...props} />
      {hint && <p className="hint" id={`${id}-hint`}>{hint}</p>}
      <p className="error" role="alert" id={`${id}-err`}>{err ?? ''}</p>
    </div>
  );
}
// the browser's clock is the owner's: a datetime-local value becomes an instant here, not on the server
const iso = (s: string) => { const d = new Date(s); return s && !isNaN(d.getTime()) ? d.toISOString() : ''; };
const Problem = ({ a }: { a: { res: { ok: true } | { ok: false; message: string; fieldErrors?: Record<string, string> } | null } }) => (a.res && !a.res.ok && !a.res.fieldErrors ? <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p> : null);

export function ExitNoticeForm({ vehicleId }: { vehicleId: string }) {
  const router = useRouter();
  const a = useAct<{ exit_date: string; retransfer_fees_paid_by: string }>();
  const [reason, setReason] = useState('');
  const [to, setTo] = useState('');
  const [ok, setOk] = useState(false);
  const [open, setOpen] = useState(false);
  if (!open) return (
    <div className="stack">
      <p className="small">30 days&apos; notice, on this vehicle only. The Exit Date is the end of the notice or, if later, the end of a rental in progress. Under 6 months on our fleet policy you pay the transfer-back registry fees; after 6 months we do. The final month&apos;s Insurance Fee comes from your prepaid last month; any unused part is refunded.</p>
      <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)}>Give notice</button>
    </div>
  );
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => giveExitNotice(vehicleId, reason, to, ok), (r) => { if (r.ok) router.refresh(); }); }} aria-label="Give exit notice">
      <Input id="ow-exit-reason" label="Reason (optional)" value={reason} set={setReason} />
      <Input id="ow-exit-to" label="Return the registration to" value={to} set={setTo} hint="Leave empty for you. Or a person's name and address." />
      <div className={`field${a.err('confirm') ? ' has-error' : ''}`}><label className="check"><input type="checkbox" checked={ok} onChange={(e) => setOk(e.target.checked)} aria-describedby="ow-exit-c-err" /><span>I give 30 days&apos; notice to take this vehicle out of the program. My other vehicles are not affected.</span></label><p className="error" role="alert" id="ow-exit-c-err">{a.err('confirm') ?? ''}</p></div>
      <Problem a={a} />
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>Notice received. Exit Date {a.res.data.exit_date}.</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Sending' : 'Give notice'}</button>
    </form>
  );
}

export function PayoutForm() {
  const router = useRouter();
  const a = useAct();
  const [p, setP] = useState<PayoutInput>({ method: 'bank_transfer', account_holder: '', institution_no: '', transit_no: '', account_no: '', e_transfer_email: '' });
  const set = (k: keyof PayoutInput) => (v: string) => setP({ ...p, [k]: v });
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => submitPayoutAccount(p), (r) => { if (r.ok) { setP({ ...p, account_no: '' }); router.refresh(); } }); }} aria-label="Payout details">
      <div className="seg" role="radiogroup" aria-label="How we pay you">
        <label><input type="radio" name="pm" checked={p.method === 'bank_transfer'} onChange={() => setP({ ...p, method: 'bank_transfer' })} />Bank transfer</label>
        <label><input type="radio" name="pm" checked={p.method === 'e_transfer'} onChange={() => setP({ ...p, method: 'e_transfer' })} />e-Transfer</label>
      </div>
      {p.method === 'bank_transfer' ? (
        <>
          <Input id="ow-po-holder" label="Account holder" value={p.account_holder ?? ''} set={set('account_holder')} autoComplete="name" />
          <div className="field-row">
            <Input id="ow-po-inst" label="Institution number" value={p.institution_no ?? ''} set={set('institution_no')} err={a.err('institution_no')} inputMode="numeric" maxLength={3} />
            <Input id="ow-po-transit" label="Transit number" value={p.transit_no ?? ''} set={set('transit_no')} err={a.err('transit_no')} inputMode="numeric" maxLength={5} />
          </div>
          <Input id="ow-po-acct" label="Account number" value={p.account_no ?? ''} set={set('account_no')} err={a.err('account_no')} inputMode="numeric" autoComplete="off" hint="On a void cheque or in your bank app. Encrypted before it is stored." />
        </>
      ) : <Input id="ow-po-email" label="e-Transfer email" value={p.e_transfer_email ?? ''} set={set('e_transfer_email')} err={a.err('e_transfer_email')} type="email" autoComplete="email" />}
      <p className="small muted">For your security we confirm new payout details by phone before we use them, and we email you that they changed.</p>
      <Problem a={a} />
      {a.res?.ok && <p className="alert alert--ok" role="status"><span className="alert__title">Received</span><span>Being verified. We call you on the number on file before the first payout to it.</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Saving' : 'Submit payout details'}</button>
    </form>
  );
}

export function OwnerProfileForm({ initial }: { initial: OwnerProfileInput }) {
  const router = useRouter();
  const a = useAct();
  const [v, setV] = useState<OwnerProfileInput>(initial);
  const f = (k: keyof OwnerProfileInput, label: string, props: Omit<React.InputHTMLAttributes<HTMLInputElement>, 'value'> = {}) => <Input id={`ow-pr-${k}`} label={label} value={v[k] ?? ''} set={(x) => setV({ ...v, [k]: x })} err={a.err(k)} {...props} />;
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => saveOwnerProfile(v), (r) => { if (r.ok) router.refresh(); }); }} aria-label="Contact details">
      {f('email', 'Email', { type: 'email', autoComplete: 'email' })}
      {f('phone', 'Phone', { type: 'tel', autoComplete: 'tel' })}
      <AddressFields idp="ow-pr" value={v as unknown as Record<string, unknown>} onChange={(p) => setV((x) => ({ ...x, ...p }))} keys={{ street: 'address_line1', unit: 'address_line2', city: 'city', province: 'province', postal_code: 'postal_code' }}
        errors={{ address_line1: a.err('address_line1'), city: a.err('city'), province: a.err('province'), postal_code: a.err('postal_code') }} />
      {f('hst_number', 'HST number (optional)', { placeholder: '123456789RT0001' })}
      <Problem a={a} />
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>Saved.</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Saving' : 'Save'}</button>
    </form>
  );
}

export function OwnBookingForm({ vehicles, initial }: { vehicles: Array<{ id: string; name: string }>; initial?: string }) {
  const a = useAct<{ bookingNumber: string }>();
  const [v, setV] = useState({ vehicle: initial && vehicles.some((x) => x.id === initial) ? initial : vehicles[0]?.id ?? '', pickup: '', ret: '', note: '' });
  if (!vehicles.length) return <p className="small muted">You can book your own car once it is enrolled and listed.</p>;
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => bookOwnCar(v.vehicle, iso(v.pickup), iso(v.ret), v.note)); }} aria-label="Book my own car">
      <div className="field"><label className="label" htmlFor="ow-ob-v">Vehicle</label><select className="select" id="ow-ob-v" value={v.vehicle} onChange={(e) => setV({ ...v, vehicle: e.target.value })}>{vehicles.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></div>
      <div className="field-row">
        <Input id="ow-ob-from" label="Pickup" type="datetime-local" value={v.pickup} set={(x) => setV({ ...v, pickup: x })} err={a.err('pickup')} />
        <Input id="ow-ob-to" label="Return" type="datetime-local" value={v.ret} set={(x) => setV({ ...v, ret: x })} err={a.err('ret')} />
      </div>
      <Input id="ow-ob-note" label="Note (optional)" value={v.note} set={(x) => setV({ ...v, note: x })} />
      <p className="small muted">No price and no deposit. A renter&apos;s confirmed booking comes first. 30 days at most. You sign the rental agreement before pickup.</p>
      <Problem a={a} />
      {a.res?.ok && <p className="alert alert--ok" role="status"><span className="alert__title">Requested</span><span>{a.res.data.bookingNumber ? <>Booking {a.res.data.bookingNumber}. Follow it in <Link href="/account">your trips</Link>.</> : 'We confirm it shortly.'}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Sending' : 'Book my car'}</button>
    </form>
  );
}
