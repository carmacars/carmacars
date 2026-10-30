'use client';
import { submitReferralPartner } from '@/server/actions/referral';
import { partnerSignupSchema } from '@/features/forms/schemas';
import { describedBy, Field } from '@/features/forms/Field';
import { Turnstile } from '@/features/forms/Turnstile';
import { AddressLookup } from '@/features/forms/AddressFields';
import { useForm } from '@/features/forms/useForm';
import type { PartnerKind } from './model';

// The sign-up on the referral program's pages (migration 0164): a pending partner for an Admin to approve.
export function PartnerSignupForm({ kind, noun }: { kind: PartnerKind; noun: string }) {
  const { state, run, pending, errors: e, clear } = useForm(partnerSignupSchema, submitReferralPartner);
  if (state?.ok) {
    return (
      <div className="stack" tabIndex={-1} ref={(el) => el?.focus()} data-testid="partner-signup-sent">
        <p className="d3">Thank you. We have your details.</p>
        <p>A person at CarmaCars reads every sign-up and writes to you by email. Once we approve your business, you get your link, your code, a flyer with a QR code for your counter and a private page for your referrals.</p>
      </div>
    );
  }
  const input = (name: string, label: string, opt = false, type = 'text', auto?: string) => (
    <Field float id={`ps-${name}`} label={label} optional={opt} error={e[name]}>
      <input className="input" placeholder=" " id={`ps-${name}`} name={name} type={type} autoComplete={auto} aria-invalid={!!e[name] || undefined} aria-describedby={describedBy(`ps-${name}`, e[name])} onInput={() => clear(name)} data-testid={`ps-${name}`} />
    </Field>
  );
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-labelledby="ps-h" data-testid="partner-signup-form">
      <h2 className="d3" id="ps-h">Join the program</h2>
      {state && !state.ok && state.code !== 'invalid' && <p className="alert alert--error" role="alert"><span>{state.message}</span></p>}
      <input type="hidden" name="kind" value={kind} />
      {input('business_name', `Your ${noun}'s name`, false, 'text', 'organization')}
      <div className="field-row">{input('contact_name', 'Who we talk to', false, 'text', 'name')}{input('phone', 'Phone', false, 'tel', 'tel')}</div>
      {input('email', 'Email', false, 'email', 'email')}
      <AddressLookup idp="ps" label="Find your business address" onParts={(p) => {
        // the lookup fills the lines below (Release 21b, item 8); each stays editable
        const put = (k: string, v: string) => { const el = document.getElementById(`ps-${k}`) as HTMLInputElement | null; if (el && v) { el.value = v; clear(k); } };
        put('address_line1', [p.street, p.unit].filter(Boolean).join(' ')); put('city', p.city); put('postal_code', p.postal_code);
      }} />
      <div className="field-row">{input('address_line1', 'Street address', true, 'text', 'street-address')}{input('city', 'City', true, 'text', 'address-level2')}{input('postal_code', 'Postal code', true, 'text', 'postal-code')}</div>
      <Field float id="ps-note" label="Anything we should know" optional error={e.note}>
        <textarea className="textarea" placeholder=" " id="ps-note" name="note" aria-invalid={!!e.note || undefined} aria-describedby={describedBy('ps-note', e.note)} onInput={() => clear('note')} />
      </Field>
      <Turnstile action="partner_signup" />
      <button className="btn btn--primary btn--lg" type="submit" disabled={pending} data-testid="ps-submit">{pending ? 'Sending' : 'Send my sign-up'}</button>
      <p className="small muted">Signing up is free. Nothing is earned until we approve your business, and a rental earns only once it is finished and paid in full.</p>
    </form>
  );
}
