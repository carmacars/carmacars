'use client';
import Link from 'next/link';
import { useState } from 'react';
import { submitOwnerApplication } from '@/server/actions/leads';
import { AddressInput, type AddressValue } from './AddressInput';
import { describedBy, Field } from './Field';
import { ownerSchema } from './schemas';
import { Turnstile } from './Turnstile';
import { useForm } from './useForm';
import { CaptureNote, useCapture } from '@/features/capture/useCapture';

export function OwnerForm({ ownersEmail, ownerReply }: { ownersEmail?: string; ownerReply: string }) {
  const [addr, setAddr] = useState<AddressValue>({ label: '', placeId: '' });
  const { state, run, pending, errors: e, clear } = useForm(ownerSchema, submitOwnerApplication);
  // contact capture (0090): the name, email and phone are saved as each becomes valid, even if the form is not sent
  const cap = useCapture('owner_lead');
  if (state?.ok) {
    return <div className="panel stack" tabIndex={-1} ref={(el) => el?.focus()}><p className="d3">Application sent.</p><p>We will reply within {ownerReply} to arrange a call about the fees for your car and the registration routes open to you.</p><p><Link className="btn" href="/">Back to home</Link></p></div>;
  }
  const inp = (id: string, name: string, extra: Record<string, unknown> = {}) => ({ className: 'input', id, name, 'aria-invalid': !!e[name] || undefined, 'aria-describedby': describedBy(id, e[name]), onInput: () => clear(name), ...extra });
  return (
    <form className="panel stack-lg" onSubmit={run} noValidate aria-labelledby="oh-apply" onBlur={(ev) => cap.onFormBlur(ev)}>
      {state && !state.ok && state.code !== 'invalid' && <p className="alert alert--error" role="alert"><span>{state.message}</span></p>}
      <div className="field-row">
        <Field id="ow-name" label="Your name" error={e.name}><input {...inp('ow-name', 'name', { autoComplete: 'name' })} /></Field>
        <Field id="ow-phone" label="Mobile number" error={e.phone}><input {...inp('ow-phone', 'phone', { type: 'tel', autoComplete: 'tel' })} /></Field>
      </div>
      <Field id="ow-email" label="Email" error={e.email}><input {...inp('ow-email', 'email', { type: 'email', autoComplete: 'email' })} /></Field>
      <Field id="ow-addr" label="Where is the car kept?" error={e.carAddress} hint="Start typing and choose the address. It helps us plan the registry visit and handovers.">
        <AddressInput id="ow-addr" name="carAddress" value={addr} onChange={(v) => { setAddr(v); clear('carAddress'); }} invalid={!!e.carAddress} describedBy={describedBy('ow-addr', e.carAddress, true)} required />
        <input type="hidden" name="carAddressPlaceId" value={addr.placeId} />
      </Field>
      <div className="field-row field-row--3">
        <Field id="ow-year" label="Year" error={e.year}><input {...inp('ow-year', 'year', { inputMode: 'numeric', maxLength: 4, placeholder: '2021' })} /></Field>
        <Field id="ow-make" label="Make" error={e.make}><input {...inp('ow-make', 'make')} /></Field>
        <Field id="ow-model" label="Model" error={e.model}><input {...inp('ow-model', 'model')} /></Field>
      </div>
      <div className="field-row">
        <Field id="ow-own" label="How is it owned?" error={e.own}>
          <select className="select" id="ow-own" name="own" defaultValue="" aria-invalid={!!e.own || undefined} aria-describedby={describedBy('ow-own', e.own)} onChange={() => clear('own')}>
            <option value="">Choose</option><option>Owned outright</option><option>Financed</option><option>Leased</option>
          </select>
        </Field>
        <Field id="ow-who" label="Registered to" error={e.who}>
          <select className="select" id="ow-who" name="who" defaultValue="" aria-invalid={!!e.who || undefined} aria-describedby={describedBy('ow-who', e.who)} onChange={() => clear('who')}>
            <option value="">Choose</option><option>Me, personally</option><option>My corporation</option>
          </select>
        </Field>
      </div>
      <fieldset className="field"><legend className="label">Which option interests you?</legend>
        <div className="seg"><label><input type="radio" name="mode" value="managed" defaultChecked />Managed</label><label><input type="radio" name="mode" value="self" />Self-managed</label><label><input type="radio" name="mode" value="turo" />Turo only</label></div>
      </fieldset>
      <CaptureNote reply={cap.reply} />
      <Turnstile action="owner_application" />
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Sending' : 'Send application'}</button>
      <p className="xs muted">We use these details to reply to you about your car. See the <Link className="link" href="/privacy">Privacy policy</Link>.{ownersEmail && <> Questions first? Email <a className="link" href={`mailto:${ownersEmail}`}>{ownersEmail}</a>.</>}</p>
    </form>
  );
}
