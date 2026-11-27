'use client';
import { submitSoftwareLead } from '@/server/actions/leads';
import { softwareLeadSchema } from '@/features/forms/schemas';
import { describedBy, Field } from '@/features/forms/Field';
import { Turnstile } from '@/features/forms/Turnstile';
import { useForm } from '@/features/forms/useForm';

// r50 hotfix 2: the pricing request of /rental-software. A lead for the team (contact, topic "Rental software"), never a
// sale: pricing is sent by a person.
export function SoftwareLeadForm() {
  const { state, run, pending, errors: e, clear } = useForm(softwareLeadSchema, submitSoftwareLead);
  if (state?.ok) {
    return (
      <div className="stack" tabIndex={-1} ref={(el) => el?.focus()} data-testid="software-lead-sent">
        <p className="d3">Thank you. We have your request.</p>
        <p>A person replies by email within one business day with pricing for your fleet and a time for a walkthrough.</p>
      </div>
    );
  }
  const input = (name: string, label: string, opt = true, type = 'text', auto?: string) => (
    <Field float id={`sw-${name}`} label={label} optional={opt} error={e[name]}>
      <input className="input" placeholder=" " id={`sw-${name}`} name={name} type={type} autoComplete={auto} aria-invalid={!!e[name] || undefined} aria-describedby={describedBy(`sw-${name}`, e[name])} onInput={() => clear(name)} />
    </Field>
  );
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-labelledby="sw-h" data-testid="software-lead-form">
      <h3 className="d3" id="sw-h">Ask for pricing and a walkthrough</h3>
      {state && !state.ok && state.code !== 'invalid' && <p className="alert alert--error" role="alert"><span>{state.message}</span></p>}
      <div className="field-row">{input('name', 'Your name', false, 'text', 'name')}{input('email', 'Work email', false, 'email', 'email')}</div>
      <div className="field-row">{input('company', 'Company', false, 'text', 'organization')}{input('phone', 'Phone', true, 'tel', 'tel')}</div>
      <div className="field-row">
        <div className="field"><label className="label" htmlFor="sw-fleet">Fleet size <span className="muted">(optional)</span></label>
          <select className="select" id="sw-fleet" name="fleet" defaultValue="">
            <option value="">Choose</option><option value="1-10">1 to 10 cars</option><option value="11-50">11 to 50 cars</option><option value="51-200">51 to 200 cars</option><option value="200+">More than 200 cars</option>
          </select></div>
        {input('website', 'Your website', true, 'url', 'url')}
      </div>
      <Field float id="sw-msg" label="What you want the software to do" optional error={e.message}>
        <textarea className="textarea" placeholder=" " id="sw-msg" name="message" aria-invalid={!!e.message || undefined} aria-describedby={describedBy('sw-msg', e.message)} onInput={() => clear('message')} />
      </Field>
      <Turnstile action="software_request" />
      <button className="btn btn--primary btn--lg" type="submit" disabled={pending}>{pending ? 'Sending' : 'Send the request'}</button>
      <p className="small muted">Nothing is charged to ask. We reply with pricing for your fleet.</p>
    </form>
  );
}
