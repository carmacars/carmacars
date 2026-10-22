'use client';
import Link from 'next/link';
import { useEffect, useRef, useState, useTransition } from 'react';
import { requestPhoneCode, savePhoneName, verifyPhoneCode } from '@/server/actions/phone-auth';
import { ChannelChoice } from '@/features/portal/NotifyChannel';
import type { Channel } from '@/features/phone/alerts';
import { cleanCode } from '@/features/auth/phone';
import { describedBy, Field } from './Field';
import { Turnstile, freshTurnstileToken } from './Turnstile';

// Sign-in by phone (migration 0091): the number, then the 6-digit code from the text (autofilled on phones:
// autocomplete one-time-code, numeric keypad), then, for a new account without a name on file, the name. Every answer
// reads the same whether or not the number has an account.
type Step = 'phone' | 'code' | 'name';
const RESEND_SECONDS = 60;

export function PhoneCodeInput({ id, value, onChange, error, autoFocus }: { id: string; value: string; onChange: (v: string) => void; error?: string; autoFocus?: boolean }) {
  return (
    <Field id={id} label="6-digit code" error={error} hint="From the text we just sent. It works for 5 minutes.">
      <input className="input input--code" id={id} name="code" value={value} autoFocus={autoFocus}
        inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]*" maxLength={7} enterKeyHint="go" spellCheck={false}
        aria-invalid={!!error || undefined} aria-describedby={describedBy(id, error, true)}
        onChange={(e) => onChange(e.target.value.replace(/[^\d\s-]/g, '').slice(0, 7))} data-testid="phone-code" />
    </Field>
  );
}

export function PhoneNumberInput({ id, value, onChange, error, hint }: { id: string; value: string; onChange: (v: string) => void; error?: string; hint?: string }) {
  return (
    <Field id={id} label="Mobile number" error={error} hint={hint ?? 'Canadian mobile numbers. We text you a 6-digit code.'}>
      <input className="input" id={id} name="phone" type="tel" inputMode="tel" autoComplete="tel" value={value} placeholder="647 555 1234"
        aria-invalid={!!error || undefined} aria-describedby={describedBy(id, error, true)} onChange={(e) => onChange(e.target.value)} data-testid="phone-number" />
    </Field>
  );
}

function useCountdown(): [number, () => void] {
  const [left, setLeft] = useState(0);
  useEffect(() => {
    if (left <= 0) return;
    const t = setTimeout(() => setLeft((n) => n - 1), 1000);
    return () => clearTimeout(t);
  }, [left]);
  return [left, () => setLeft(RESEND_SECONDS)];
}

export function PhoneSignInForm({ next, onUseEmail, signUp, minAge, idPrefix = 'ps' }: { next?: string; onUseEmail?: () => void; signUp?: boolean; minAge?: string; idPrefix?: string }) {
  const [step, setStep] = useState<Step>('phone');
  const [phone, setPhone] = useState('');
  const [sentTo, setSentTo] = useState<{ phone: string; display: string } | null>(null);
  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [agree, setAgree] = useState(false);
  // 0096: how we reach a new account made by phone (Text by default: it has no email yet)
  const [channel, setChannel] = useState<Channel>('text');
  const [err, setErr] = useState<{ field?: string; message: string } | null>(null);
  const [pending, start] = useTransition();
  const [left, restart] = useCountdown();
  const form = useRef<HTMLFormElement>(null);

  const ask = () => start(async () => {
    setErr(null);
    if (signUp) {
      if (name.trim().length < 2) { setErr({ field: 'name', message: 'Enter your name.' }); return; }
      if (!agree) { setErr({ field: 'agree', message: 'Tick this box to create an account.' }); return; }
    }
    // a fresh token for each request: a token is single use, so "Send a new code" needs its own
    const token = form.current ? await freshTurnstileToken(form.current) : null;
    if (!token) { setErr({ message: 'Our security check did not load in this browser (a content blocker or a privacy setting can block it). Turn it off for carmacars.ca or try another browser, or sign in with your email.' }); return; }
    const r = await requestPhoneCode({ phone, purpose: 'sign_in', turnstile: token });
    if (!r.ok) { setErr({ field: r.fieldErrors?.phone ? 'phone' : undefined, message: r.message }); return; }
    setSentTo(r.data); setCode(''); setStep('code'); restart();
  });
  const check = (value = code) => start(async () => {
    setErr(null);
    if (!sentTo) return;
    if (!cleanCode(value)) { setErr({ field: 'code', message: 'Enter the 6 digits from the text.' }); return; }
    const r = await verifyPhoneCode({ phone: sentTo.phone, code: value, purpose: 'sign_in', next: next ?? null, name: signUp ? name : null, channel: signUp ? channel : null });
    // on success the action moves on to the next page; it comes back only to ask the name, or with an error
    if (!r) return;
    if (!r.ok) { setErr({ field: r.fieldErrors?.code ? 'code' : undefined, message: r.message }); return; }
    if (r.data?.needsName) setStep('name');
  });
  const saveName = () => start(async () => {
    setErr(null);
    const r = await savePhoneName(name, next ?? null);
    if (r && !r.ok) setErr({ field: 'name', message: r.message });
  });

  const fieldErr = (f: string) => (err?.field === f ? err.message : undefined);
  return (
    <form ref={form} className="stack-lg" noValidate aria-label={signUp ? 'Create an account with your phone number' : 'Sign in with your phone number'} data-testid="phone-signin"
      onSubmit={(e) => { e.preventDefault(); if (step === 'phone') ask(); else if (step === 'code') check(); else saveName(); }}>
      {err && !err.field && <p className="alert alert--error" role="alert"><span>{err.message}</span></p>}
      {/* kept mounted on the code step too, so "Send a new code" gets a token of its own */}
      <Turnstile action="phone_code" />
      {step === 'phone' && <>
        {signUp && <Field id={`${idPrefix}-name`} label="Full name" error={fieldErr('name')}><input className="input" id={`${idPrefix}-name`} name="name" autoComplete="name" value={name} onChange={(e) => setName(e.target.value)} aria-invalid={!!fieldErr('name') || undefined} aria-describedby={describedBy(`${idPrefix}-name`, fieldErr('name'))} /></Field>}
        <PhoneNumberInput id={`${idPrefix}-phone`} value={phone} onChange={setPhone} error={fieldErr('phone')} />
        {signUp && <div className={`field${fieldErr('agree') ? ' has-error' : ''}`}>
          <label className="check"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} aria-invalid={!!fieldErr('agree') || undefined} aria-describedby={fieldErr('agree') ? `${idPrefix}-agree-err` : undefined} /><span className="small">I am {minAge ?? '21'} or older and agree to the <Link className="link" href="/terms">Terms of use</Link> and <Link className="link" href="/privacy">Privacy policy</Link>.</span></label>
          <p className="error" role="alert" id={`${idPrefix}-agree-err`}>{fieldErr('agree') ?? ''}</p>
        </div>}
        {signUp && <ChannelChoice name={`${idPrefix}-channel`} value={channel} onChange={setChannel} testId="signup-channel" hint="Texts come from the CarmaCars number. Reply STOP to any text to stop them. You can change this in your profile." />}
        <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending} data-testid="phone-send">{pending ? 'Sending the code' : 'Text me a code'}</button>
        <p className="small muted">We text the code from the CarmaCars number. Message and data rates may apply.</p>
      </>}
      {step === 'code' && sentTo && <>
        <p role="status" data-testid="phone-sent">We texted a 6-digit code to <strong>{sentTo.display}</strong>.</p>
        <PhoneCodeInput id={`${idPrefix}-code`} value={code} autoFocus error={fieldErr('code')}
          onChange={(v) => { setCode(v); if (cleanCode(v) && !pending) check(v); }} />
        <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending} data-testid="phone-verify">{pending ? 'Checking' : signUp ? 'Create my account' : 'Sign in'}</button>
        <p className="row small" style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}>
          <button type="button" className="link" disabled={pending || left > 0} onClick={ask} data-testid="phone-resend">{left > 0 ? `Send a new code in ${left} s` : 'Send a new code'}</button>
          <button type="button" className="link" onClick={() => { setStep('phone'); setErr(null); }}>Use another number</button>
        </p>
      </>}
      {step === 'name' && <>
        <p role="status">You are signed in. What is your name?</p>
        <Field id={`${idPrefix}-newname`} label="Full name" error={fieldErr('name')} hint="As on your driver's licence."><input className="input" id={`${idPrefix}-newname`} name="name" autoComplete="name" autoFocus value={name} onChange={(e) => setName(e.target.value)} aria-invalid={!!fieldErr('name') || undefined} aria-describedby={describedBy(`${idPrefix}-newname`, fieldErr('name'), true)} data-testid="phone-name" /></Field>
        <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending} data-testid="phone-name-save">{pending ? 'Saving' : 'Continue'}</button>
      </>}
      {onUseEmail && step === 'phone' && <p className="small"><button type="button" className="link" onClick={onUseEmail} data-testid="use-email">Use my email instead</button></p>}
    </form>
  );
}
