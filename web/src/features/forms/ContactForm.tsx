'use client';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { submitContact } from '@/server/actions/leads';
import { contactSchema } from './schemas';
import { describedBy, Field } from './Field';
import { Turnstile } from './Turnstile';
import { useForm } from './useForm';
import { CaptureNote, useCapture } from '@/features/capture/useCapture';

const TOPICS: [string, string][] = [['car', 'A car or a price'], ['booking', 'A booking I have made'], ['dates', 'Dates or availability'], ['owner', 'Listing my car'], ['billing', 'A charge or a statement'], ['other', 'Something else']];

export function ContactForm({ reply }: { reply: string }) {
  const sp = useSearchParams();
  const topic = TOPICS.some(([k]) => k === sp.get('topic')) ? sp.get('topic')! : 'car';
  const car = sp.get('car');
  const { state, run, pending, errors, clear } = useForm(contactSchema, submitContact);
  // contact capture (0090): the name, email and phone are saved as each becomes valid, even if the form is not sent
  const cap = useCapture('contact');
  if (state?.ok) {
    return <div className="stack" tabIndex={-1} ref={(el) => el?.focus()}><p className="d3">Message sent.</p><p>{reply}, by email or by text.</p><p><Link className="btn" href="/cars">Browse the fleet</Link></p></div>;
  }
  const e = errors;
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Send us a message" onBlur={(ev) => cap.onFormBlur(ev)}>
      <h2 className="d3">Send a message</h2>
      {state && !state.ok && state.code !== 'invalid' && <p className="alert alert--error" role="alert"><span>{state.message}</span></p>}
      <div className="field"><label className="label" htmlFor="ct-topic">What is it about?</label>
        <select className="select" id="ct-topic" name="topic" defaultValue={topic}>{TOPICS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
      <div className="field-row">
        <Field float id="ct-name" label="Your name" error={e.name}><input className="input" placeholder=" " id="ct-name" name="name" autoComplete="name" aria-invalid={!!e.name || undefined} aria-describedby={describedBy('ct-name', e.name)} onInput={() => clear('name')} /></Field>
        <Field float id="ct-email" label="Email" hint="Or give a mobile number below." error={e.email}><input className="input" placeholder=" " id="ct-email" name="email" type="email" autoComplete="email" aria-invalid={!!e.email || undefined} aria-describedby={describedBy('ct-email', e.email, true)} onInput={() => clear('email')} /></Field>
      </div>
      <Field float id="ct-phone" label="Mobile number" optional error={e.phone}><input className="input" placeholder=" " id="ct-phone" name="phone" type="tel" inputMode="tel" autoComplete="tel" aria-invalid={!!e.phone || undefined} aria-describedby={describedBy('ct-phone', e.phone)} onInput={() => clear('email')} /></Field>
      <Field float id="ct-ref" label="Booking or request number" optional error={e.ref}><input className="input" placeholder=" " id="ct-ref" name="ref" /></Field>
      <Field float id="ct-msg" label="Message" error={e.message}>
        <textarea className="textarea" placeholder=" " id="ct-msg" name="message" defaultValue={car ? `About the car: ${car}\n` : ''} aria-invalid={!!e.message || undefined} aria-describedby={describedBy('ct-msg', e.message)} onInput={() => clear('message')} />
      </Field>
      <CaptureNote reply={cap.reply} />
      <Turnstile action="contact" />
      <button className="btn btn--primary btn--lg" type="submit" disabled={pending}>{pending ? 'Sending' : 'Send message'}</button>
    </form>
  );
}
