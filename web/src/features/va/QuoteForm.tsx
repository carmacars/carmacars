'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { vaAct } from '@/server/actions/va';

// A quote from a phone, email or WhatsApp lead (05-va.md section 5, /va/sales/quotes/new): the staff request
// form. It becomes a request (the database prices it and checks the car, the ages and the licence), then
// the offer is sent from the booking's review screen.
export function QuoteForm({ vehicles, minNotice }: { vehicles: Array<{ id: string; name: string }>; minNotice: number }) {
  const router = useRouter();
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <form className="ad-form" data-testid="quote-form" onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); start(async () => {
      const iso = (k: string) => { const v = String(fd.get(k) ?? ''); return v ? new Date(v).toISOString() : null; };
      const r = await vaAct<{ booking_number: string }>('quote_create', {
        vehicle_id: fd.get('vehicle_id'), pickup_at: iso('pickup_at'), return_at: iso('return_at'), source: fd.get('source'),
        full_name: fd.get('full_name'), email: fd.get('email'), mobile: fd.get('mobile'), date_of_birth: fd.get('date_of_birth'), licence_class: fd.get('licence_class'),
        coverage_option: fd.get('coverage_option') ? Number(fd.get('coverage_option')) : null, note: fd.get('note') });
      if (!r.ok) { setErr(r.message); return; }
      router.push(`/va/bookings/${encodeURIComponent(r.data.booking_number)}?tab=review`);
    }); }}>
      <div className="field"><label className="label" htmlFor="q-car">Car</label><select className="select" id="q-car" name="vehicle_id" required defaultValue="">
        <option value="" disabled>Choose the car</option>{vehicles.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></div>
      <div className="field"><label className="label" htmlFor="q-from">Pickup</label><input className="input" id="q-from" name="pickup_at" type="datetime-local" required aria-describedby="q-from-hint" />
        <p className="hint" id="q-from-hint">At least {Math.round(minNotice / 60)} hours from now.</p></div>
      <div className="field"><label className="label" htmlFor="q-to">Return</label><input className="input" id="q-to" name="return_at" type="datetime-local" required /></div>
      <div className="field"><label className="label" htmlFor="q-src">Lead came by</label><select className="select" id="q-src" name="source" defaultValue="phone"><option value="phone">Phone</option><option value="email">Email</option><option value="whatsapp">WhatsApp</option></select></div>
      <div className="field"><label className="label" htmlFor="q-name">Full legal name</label><input className="input" id="q-name" name="full_name" required autoComplete="off" /></div>
      <div className="field"><label className="label" htmlFor="q-email">Email</label><input className="input" id="q-email" name="email" type="email" required autoComplete="off" /></div>
      <div className="field"><label className="label" htmlFor="q-mobile">Mobile</label><input className="input" id="q-mobile" name="mobile" type="tel" required autoComplete="off" /></div>
      <div className="field"><label className="label" htmlFor="q-dob">Date of birth</label><input className="input" id="q-dob" name="date_of_birth" type="date" required /></div>
      <div className="field"><label className="label" htmlFor="q-class">Licence class</label><select className="select" id="q-class" name="licence_class" defaultValue="G"><option value="G">G</option><option value="G2">G2</option></select></div>
      <div className="field"><label className="label" htmlFor="q-cov">Damage cover</label><select className="select" id="q-cov" name="coverage_option" defaultValue=""><option value="">Not chosen yet</option><option value="1">Option 1: their own policy</option><option value="2">Option 2: their credit card</option></select></div>
      <div className="field ad-field--wide"><label className="label" htmlFor="q-note">Note (places, extras, what they asked)</label><textarea className="input ad-textarea" id="q-note" name="note" rows={3} maxLength={1000} /></div>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={pending} data-testid="quote-create">{pending ? 'Creating' : 'Create the request'}</button>
    </form>
  );
}
