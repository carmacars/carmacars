'use client';
import { submitVehicleLead } from '@/server/actions/leads';
import { vehicleLeadSchema } from '@/features/forms/schemas';
import { describedBy, Field } from '@/features/forms/Field';
import { Turnstile } from '@/features/forms/Turnstile';
import { useForm } from '@/features/forms/useForm';

// The vehicle pages' lead forms (migration 0097): "Find me this car" on a for-sale page, a financing or leasing
// question, a detailing or body shop request. Each is a lead for Sales (Leads, with a To do line).
// auto_service (0123): mechanical work we arrange with a trusted shop, never do ourselves; no marketing consent asked
type Kind = 'buyer' | 'finance' | 'detailing' | 'bodyshop' | 'auto_service';
const BUTTON: Record<Kind, string> = { buyer: 'Find me this car', finance: 'Send my question', detailing: 'Request detailing', bodyshop: 'Request the repair', auto_service: 'Request it' };
export function LeadForm({ kind, vehicle, service, place, marketingText, disclaimer }: { kind: Kind; vehicle: string; service?: string; place?: string; marketingText: string; disclaimer?: string }) {
  const { state, run, pending, errors: e, clear } = useForm(vehicleLeadSchema, submitVehicleLead);
  const id = (x: string) => `vl-${x}`;
  if (state?.ok) return <div className="stack" tabIndex={-1} ref={(el) => el?.focus()} data-testid="lead-sent"><p className="d4">Thanks. We have your request.</p><p className="small muted">Someone from our team replies within one business day.</p></div>;
  const money = kind === 'buyer' || kind === 'finance';
  return (
    <form className="stack" onSubmit={run} noValidate aria-label={BUTTON[kind]} data-testid="lead-form">
      {state && !state.ok && state.code !== 'invalid' && <p className="alert alert--error" role="alert"><span>{state.message}</span></p>}
      <input type="hidden" name="kind" value={kind} /><input type="hidden" name="vehicle" value={vehicle} />
      {service && <input type="hidden" name="service" value={service} />}{place && <input type="hidden" name="place" value={place} />}
      <Field float id={id('name')} label="Your name" error={e.name}><input className="input" placeholder=" " id={id('name')} name="name" autoComplete="name" aria-invalid={!!e.name || undefined} aria-describedby={describedBy(id('name'), e.name)} onInput={() => clear('name')} /></Field>
      <div className="field-row">
        <Field float id={id('email')} label="Email" error={e.email}><input className="input" placeholder=" " id={id('email')} name="email" type="email" autoComplete="email" aria-invalid={!!e.email || undefined} aria-describedby={describedBy(id('email'), e.email)} onInput={() => clear('email')} /></Field>
        <Field float id={id('phone')} label="Phone" optional error={e.phone}><input className="input" placeholder=" " id={id('phone')} name="phone" type="tel" autoComplete="tel" aria-invalid={!!e.phone || undefined} aria-describedby={describedBy(id('phone'), e.phone)} /></Field>
      </div>
      <div className="field-row">
        {money ? <Field float id={id('budget')} label="Budget" optional error={e.budget}><input className="input" placeholder=" " id={id('budget')} name="budget" inputMode="numeric" /></Field>
          : <Field float id={id('note')} label="What needs doing" optional error={e.note}><input className="input" placeholder=" " id={id('note')} name="note" /></Field>}
        <div className="field"><label className="label" htmlFor={id('when')}>{money ? 'When do you want to buy?' : 'When?'}</label>
          <select className="select" id={id('when')} name="timeline" defaultValue={money ? 'month' : 'week'}>
            {!money && <option value="week">This week</option>}<option value="now">{money ? 'Now' : 'As soon as possible'}</option><option value="month">Within a month</option><option value="three">Within three months</option><option value="later">Later</option></select></div>
      </div>
      {disclaimer && <p className="small muted" data-testid="lead-disclaimer">{disclaimer}</p>}
      {marketingText && kind !== 'auto_service' && <label className="check"><input type="checkbox" name="marketing" /><span className="small">{marketingText}</span></label>}
      <Turnstile action={`lead-${kind}`} />
      <button className="btn btn--primary" type="submit" disabled={pending}>{pending ? 'Sending' : BUTTON[kind]}</button>
    </form>
  );
}
