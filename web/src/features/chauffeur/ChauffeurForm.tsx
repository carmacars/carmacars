'use client';
import Link from 'next/link';
import { useMemo, useState } from 'react';
import { describedBy, Field } from '@/features/forms/Field';
import { Turnstile } from '@/features/forms/Turnstile';
import { useForm } from '@/features/forms/useForm';
import { money } from '@/lib/format';
import { submitChauffeur } from '@/server/actions/chauffeur';
import { chauffeurPrice, chauffeurSchema, OCCASIONS, type ChauffeurVehicle } from './schema';

const TIMES = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`);
const clock = (t: string) => { const [h, m] = t.split(':').map(Number); return `${((h! + 11) % 12) + 1}:${String(m).padStart(2, '0')} ${h! < 12 ? 'am' : 'pm'}`; };

// The chauffeur request form (migration 0093): the vehicle, the date and start time, the hours (2 at least), the
// addresses, passengers, occasion and notes, and how to reach you. The price updates as you choose; staff confirm the
// vehicle and the driver and send the quote before anything is paid.
export function ChauffeurForm({ vehicles, initial, today, hstBps }: { vehicles: ChauffeurVehicle[]; initial: string | null; today: string; hstBps: number }) {
  const { state, run, pending, errors, clear } = useForm(chauffeurSchema, submitChauffeur);
  const [vid, setVid] = useState(vehicles.find((v) => v.slug === initial)?.id ?? vehicles[0]?.id ?? '');
  const [hours, setHours] = useState(3);
  const [key] = useState(() => (typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : String(Date.now())));
  const v = vehicles.find((x) => x.id === vid) ?? null;
  const price = useMemo(() => (v ? chauffeurPrice(v, hours) : 0), [v, hours]);
  if (state?.ok) {
    const ref = (state.data as { reference: string }).reference;
    return (
      <div className="stack" tabIndex={-1} ref={(el) => el?.focus()} data-testid="chauffeur-sent">
        <p className="d3">Request {ref} sent.</p>
        <p>We check the vehicle and the driver for your time and send your quote by email, usually within the hour during opening hours. Nothing is charged until you confirm.</p>
        <p><Link className="btn" href="/chauffeur">Back to the chauffeur service</Link></p>
      </div>
    );
  }
  const e = errors;
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Request a chauffeur" data-testid="chauffeur-form">
      {state && !state.ok && state.code !== 'invalid' && <p className="alert alert--error" role="alert"><span>{state.message}</span></p>}
      <input type="hidden" name="request_key" value={key} />
      <div className={`field${e.vehicle_id ? ' has-error' : ''}`}><label className="label" htmlFor="ch-vehicle">Vehicle</label>
        <select className="select" id="ch-vehicle" name="vehicle_id" value={vid} onChange={(x) => { setVid(x.target.value); clear('vehicle_id'); }} aria-invalid={!!e.vehicle_id || undefined} aria-describedby={describedBy('ch-vehicle', e.vehicle_id)}>
          {vehicles.map((x) => <option key={x.id} value={x.id}>{x.name}, up to {x.passengers} passengers</option>)}
        </select>
        {e.vehicle_id && <p className="error" id="ch-vehicle-err" role="alert">{e.vehicle_id}</p>}</div>
      <div className="field-row">
        <Field id="ch-date" label="Date" error={e.date}><input className="input" id="ch-date" name="date" type="date" min={today} aria-invalid={!!e.date || undefined} aria-describedby={describedBy('ch-date', e.date)} onInput={() => clear('date')} /></Field>
        <Field id="ch-time" label="Start time" error={e.start_time}><select className="select" id="ch-time" name="start_time" defaultValue="18:00" aria-invalid={!!e.start_time || undefined}>{TIMES.map((t) => <option key={t} value={t}>{clock(t)}</option>)}</select></Field>
        <Field id="ch-hours" label="Hours" error={e.hours}><select className="select" id="ch-hours" name="hours" value={hours} onChange={(x) => setHours(Number(x.target.value))} aria-invalid={!!e.hours || undefined}>
          {Array.from({ length: 23 }, (_, i) => i + 2).map((h) => <option key={h} value={h}>{h} hours</option>)}</select></Field>
      </div>
      <Field float id="ch-pickup" label="Pickup address" error={e.pickup_address}><input className="input" placeholder=" " id="ch-pickup" name="pickup_address" autoComplete="street-address" aria-invalid={!!e.pickup_address || undefined} aria-describedby={describedBy('ch-pickup', e.pickup_address)} onInput={() => clear('pickup_address')} /></Field>
      <Field float id="ch-dropoff" label="Drop-off address" optional error={e.dropoff_address}><input className="input" placeholder=" " id="ch-dropoff" name="dropoff_address" /></Field>
      <div className="field-row">
        <Field id="ch-pax" label="Passengers" error={e.passengers}><input className="input" id="ch-pax" name="passengers" type="number" min={1} max={v?.passengers ?? 20} defaultValue={2} inputMode="numeric" aria-invalid={!!e.passengers || undefined} aria-describedby={describedBy('ch-pax', e.passengers)} onInput={() => clear('passengers')} /></Field>
        <Field id="ch-occasion" label="Occasion" optional error={e.occasion}><select className="select" id="ch-occasion" name="occasion" defaultValue=""><option value="">Choose one</option>{OCCASIONS.map((o) => <option key={o} value={o}>{o}</option>)}</select></Field>
      </div>
      <Field float id="ch-notes" label="Notes: stops, flight number, anything we should know" optional error={e.notes}><textarea className="textarea" placeholder=" " id="ch-notes" name="notes" /></Field>
      <div className="field-row">
        <Field float id="ch-name" label="Your name" error={e.name}><input className="input" placeholder=" " id="ch-name" name="name" autoComplete="name" aria-invalid={!!e.name || undefined} aria-describedby={describedBy('ch-name', e.name)} onInput={() => clear('name')} /></Field>
        <Field float id="ch-email" label="Email" error={e.email}><input className="input" placeholder=" " id="ch-email" name="email" type="email" autoComplete="email" aria-invalid={!!e.email || undefined} aria-describedby={describedBy('ch-email', e.email)} onInput={() => clear('email')} /></Field>
      </div>
      <Field float id="ch-phone" label="Mobile" error={e.phone}><input className="input" placeholder=" " id="ch-phone" name="phone" type="tel" autoComplete="tel" aria-invalid={!!e.phone || undefined} aria-describedby={describedBy('ch-phone', e.phone)} onInput={() => clear('phone')} /></Field>
      {v && (
        <div className="estimate" aria-live="polite" data-testid="chauffeur-estimate">
          <table className="spec spec--num"><tbody>
            <tr><th scope="row">{v.name}, {hours} hours at {money(hours === 2 ? v.rate_2h_cents : v.rate_3plus_cents)} an hour</th><td>{money(price)}</td></tr>
            <tr><th scope="row">HST</th><td>{money(Math.round((price * hstBps) / 10000))}</td></tr>
            <tr><th scope="row"><b>Estimated total</b></th><td><b data-testid="chauffeur-total">{money(price + Math.round((price * hstBps) / 10000))}</b></td></tr>
          </tbody></table>
          <p className="small muted">Guideline rates; final price confirmed after review. No payment to send a request.</p>
        </div>
      )}
      <Turnstile action="chauffeur" />
      <button className="btn btn--primary btn--lg" type="submit" disabled={pending}>{pending ? 'Sending' : 'Send request'}</button>
    </form>
  );
}
