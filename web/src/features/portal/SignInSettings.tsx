'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { requestPhoneCode, saveAccountEmail, setSignInMethod, verifyPhoneCode } from '@/server/actions/phone-auth';
import { cleanCode, formatPhone } from '@/features/auth/phone';
import { PhoneCodeInput, PhoneNumberInput } from '@/features/forms/PhoneSignIn';
import { describedBy, Field } from '@/features/forms/Field';

// The profile pages' sign-in card (renter, owner, assistants, field staff; migration 0091): add and verify a phone
// with a texted code, add an email to an account made by phone, and choose phone or email sign-in.
export interface SignInState { email: string | null; email_verified: boolean; phone: string | null; phone_verified: boolean; phone_on_file: string | null; preferred: 'email' | 'phone'; us_allowed: boolean; enabled: boolean }

export function SignInSettings({ state, className = 'pt-card' }: { state: SignInState; className?: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [adding, setAdding] = useState(false);
  const [phone, setPhone] = useState(state.phone_on_file ? formatPhone(state.phone_on_file) : '');
  const [sentTo, setSentTo] = useState<{ phone: string; display: string } | null>(null);
  const [code, setCode] = useState('');
  const [email, setEmail] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string; field?: string } | null>(null);
  const [preferred, setPreferred] = useState(state.preferred);

  const ask = () => start(async () => {
    setMsg(null);
    const r = await requestPhoneCode({ phone, purpose: 'add' });
    if (!r.ok) { setMsg({ ok: false, text: r.message, field: r.fieldErrors?.phone ? 'phone' : undefined }); return; }
    setSentTo(r.data); setCode('');
  });
  const check = (v = code) => start(async () => {
    setMsg(null);
    if (!sentTo || !cleanCode(v)) { setMsg({ ok: false, text: 'Enter the 6 digits from the text.', field: 'code' }); return; }
    const r = await verifyPhoneCode({ phone: sentTo.phone, code: v, purpose: 'add' });
    if (!r.ok) { setMsg({ ok: false, text: r.message, field: r.fieldErrors?.code ? 'code' : undefined }); return; }
    setAdding(false); setSentTo(null); setMsg({ ok: true, text: `${r.data?.phone ?? sentTo.display} is verified. You can sign in with it.` });
    router.refresh();
  });
  const choose = (m: 'email' | 'phone') => { const was = preferred; setPreferred(m); setMsg(null); start(async () => {
    const r = await setSignInMethod(m);
    if (!r.ok) { setPreferred(was); setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: m === 'phone' ? 'You sign in with your phone number. The sign-in page opens on it.' : 'You sign in with your email and password.' });
  }); };
  const addEmail = () => start(async () => {
    setMsg(null);
    const r = await saveAccountEmail(email);
    if (!r.ok) { setMsg({ ok: false, text: r.message, field: 'email' }); return; }
    setMsg({ ok: true, text: `Saved. We emailed ${r.data.email} a link to confirm it.` });
    router.refresh();
  });
  const err = (f: string) => (msg && !msg.ok && msg.field === f ? msg.text : undefined);

  return (
    <section className={className} aria-labelledby="si-settings" data-testid="signin-settings">
      <h2 className="d4" id="si-settings">Sign-in</h2>
      <dl className="pt-dl">
        <div><dt>Email</dt><dd data-testid="signin-email">{state.email ? <>{state.email}{state.email_verified ? '' : ' (not confirmed yet: open the link we emailed)'}</> : 'None yet'}</dd></div>
        <div><dt>Phone</dt><dd data-testid="signin-phone">{state.phone_verified && state.phone ? <>{formatPhone(state.phone)} <span className="badge badge--outline">Verified</span></> : 'Not added'}</dd></div>
      </dl>
      {msg && !msg.field && <p className={msg.ok ? 'alert alert--ok' : 'alert alert--error'} role={msg.ok ? 'status' : 'alert'} data-testid="signin-msg"><span>{msg.text}</span></p>}

      {state.enabled && !adding && <p><button type="button" className="btn btn--ghost btn--sm" onClick={() => { setAdding(true); setMsg(null); }} data-testid="phone-add">{state.phone_verified ? 'Change my phone number' : 'Add and verify my phone number'}</button></p>}
      {adding && (
        <form className="stack" noValidate aria-label="Verify a phone number" onSubmit={(e) => { e.preventDefault(); if (sentTo) check(); else ask(); }}>
          {!sentTo ? <>
            <PhoneNumberInput id="si-phone" value={phone} onChange={setPhone} error={err('phone')} hint={state.us_allowed ? 'Canadian and US mobile numbers. We text you a 6-digit code.' : 'Canadian mobile numbers. We text you a 6-digit code.'} />
            <p className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="phone-send">{pending ? 'Sending' : 'Text me a code'}</button>
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setAdding(false); setMsg(null); }}>Cancel</button></p>
          </> : <>
            <p role="status" data-testid="phone-sent">We texted a 6-digit code to <strong>{sentTo.display}</strong>.</p>
            <PhoneCodeInput id="si-code" value={code} autoFocus error={err('code')} onChange={(v) => { setCode(v); if (cleanCode(v) && !pending) check(v); }} />
            <p className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="phone-verify">{pending ? 'Checking' : 'Verify'}</button>
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setSentTo(null); setMsg(null); }}>Use another number</button></p>
          </>}
        </form>
      )}

      {!state.email && (
        <form className="stack" noValidate aria-label="Add an email" onSubmit={(e) => { e.preventDefault(); addEmail(); }}>
          <Field id="si-email" label="Email" error={err('email')} hint="For receipts and messages. Needed before your first payment."><input className="input" id="si-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} aria-invalid={!!err('email') || undefined} aria-describedby={describedBy('si-email', err('email'), true)} data-testid="signin-email-input" /></Field>
          <p><button className="btn btn--primary btn--sm" type="submit" disabled={pending}>Save my email</button></p>
        </form>
      )}

      <fieldset className="field" aria-describedby="si-pref-hint">
        <legend className="label">Sign in with</legend>
        <label className="check"><input type="radio" name="si-pref" checked={preferred === 'phone'} disabled={pending || !state.phone_verified} onChange={() => choose('phone')} data-testid="pref-phone" /><span>My phone number (a code by text)</span></label>
        <label className="check"><input type="radio" name="si-pref" checked={preferred === 'email'} disabled={pending || !state.email} onChange={() => choose('email')} data-testid="pref-email" /><span>My email and password</span></label>
        <p className="hint" id="si-pref-hint">{state.phone_verified ? 'Both keep working; this is the one the sign-in page opens on.' : 'Verify a phone number to sign in with a texted code.'}</p>
      </fieldset>
    </section>
  );
}
