'use client';
import Link from 'next/link';
import { submitPlaceLead } from '@/server/actions/leads';
import { placeLeadSchema } from '@/features/forms/schemas';
import { describedBy, Field } from '@/features/forms/Field';
import { Turnstile } from '@/features/forms/Turnstile';
import { useForm } from '@/features/forms/useForm';

// The request on a place page and the service pages (migration 0095): what we need to reply, by kind. A request is a
// lead with a task for the team, never a booking or a payment.
type Kind = 'buyer' | 'finance' | 'place_request' | 'detailing' | 'bodyshop';
const TITLE: Record<Kind, string> = { buyer: 'Find me this car', finance: 'Ask about financing or lease options', place_request: 'Request a car', detailing: 'Request detailing', bodyshop: 'Request body work' };

export function PlaceLeadForm({ kind, place, term, services = [], heading, id = 'request', reply = '' }: { kind: Kind; place?: string; term?: string; services?: string[]; heading?: string; id?: string; reply?: string }) {
  const { state, run, pending, errors: e, clear } = useForm(placeLeadSchema, submitPlaceLead);
  const p = `pl-${id}`;
  if (state?.ok) {
    return (
      <div className="stack" tabIndex={-1} ref={(el) => el?.focus()} data-testid="place-lead-sent">
        <p className="d3">Request sent.</p>
        <p>A person reads every request and replies by email or phone{reply ? `, ${reply.replace(/^We reply /, '')}` : ''}.</p>
        <p><Link className="btn" href="/cars">See the cars for rent</Link></p>
      </div>
    );
  }
  const input = (name: string, label: string, opt = true, type = 'text', auto?: string) => (
    <Field float id={`${p}-${name}`} label={label} optional={opt} error={e[name]}>
      <input className="input" placeholder=" " id={`${p}-${name}`} name={name} type={type} autoComplete={auto} aria-invalid={!!e[name] || undefined} aria-describedby={describedBy(`${p}-${name}`, e[name])} onInput={() => clear(name)} />
    </Field>
  );
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-labelledby={`${p}-h`} data-testid="place-lead-form">
      <h2 className="d3" id={`${p}-h`}>{heading ?? TITLE[kind]}</h2>
      {state && !state.ok && state.code !== 'invalid' && <p className="alert alert--error" role="alert"><span>{state.message}</span></p>}
      <input type="hidden" name="kind" value={kind} />
      {term && <input type="hidden" name="term" value={term} />}
      <div className="field-row">{input('name', 'Your name', false, 'text', 'name')}{input('email', 'Email', false, 'email', 'email')}</div>
      {input('phone', 'Phone', true, 'tel', 'tel')}
      {(kind === 'buyer' || kind === 'detailing' || kind === 'bodyshop' || kind === 'finance') && input('vehicle', kind === 'buyer' ? 'The car you are looking for' : 'Your car (year, make and model)')}
      {(kind === 'detailing' || kind === 'bodyshop') && services.length > 0 && (
        <div className="field"><label className="label" htmlFor={`${p}-service`}>Service</label>
          <select className="select" id={`${p}-service`} name="service" defaultValue={services[0]}>{services.map((s) => <option key={s} value={s}>{s}</option>)}</select></div>
      )}
      {kind === 'bodyshop' && input('damage', 'The damage, in a few words')}
      {kind === 'bodyshop' && (
        <fieldset className="field"><legend className="label">Is it an insurance claim?</legend>
          <div className="row"><label className="check"><input type="radio" name="insurance_claim" value="yes" /> <span>Yes</span></label>
            <label className="check"><input type="radio" name="insurance_claim" value="no" /> <span>No</span></label></div></fieldset>
      )}
      {kind === 'detailing' && (
        <fieldset className="field"><legend className="label">Where</legend>
          <div className="row"><label className="check"><input type="radio" name="where" value="mobile" defaultChecked /> <span>At my place (mobile)</span></label>
            <label className="check"><input type="radio" name="where" value="drop_off" /> <span>I drop the car off</span></label></div></fieldset>
      )}
      <Field float id={`${p}-place`} label="Where you are (city or neighbourhood)" optional error={e.place}>
        <input className="input" placeholder=" " id={`${p}-place`} name="place" defaultValue={place ?? ''} aria-invalid={!!e.place || undefined} />
      </Field>
      {(kind === 'detailing' || kind === 'bodyshop' || kind === 'place_request') && input('date', 'The date you have in mind', true, 'date')}
      <Field float id={`${p}-msg`} label="Anything else" optional error={e.message}>
        <textarea className="textarea" placeholder=" " id={`${p}-msg`} name="message" aria-invalid={!!e.message || undefined} aria-describedby={describedBy(`${p}-msg`, e.message)} onInput={() => clear('message')} />
      </Field>
      <Turnstile action="place_request" />
      <button className="btn btn--primary btn--lg" type="submit" disabled={pending}>{pending ? 'Sending' : 'Send the request'}</button>
    </form>
  );
}
