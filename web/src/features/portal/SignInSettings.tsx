'use client';
import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { requestPhoneCode, saveAccountEmail, saveContactPhone, setSignInMethod, verifyPhoneCode } from '@/server/actions/phone-auth';
import { cleanCode, formatPhone } from '@/features/auth/phone';
import { PhoneCodeInput, PhoneNumberInput } from '@/features/forms/PhoneSignIn';
import { describedBy, Field } from '@/features/forms/Field';
import { ChangeEmail } from './ChangeEmail';

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
  // hotfix 0843: a number outside Canada (no texted code) is saved as the contact number
  const [contact, setContact] = useState(state.phone_on_file && !state.phone_verified ? state.phone_on_file : '');
  const saveContact = () => start(async () => {
    setMsg(null);
    const r = await saveContactPhone({ phone: contact });
    if (!r.ok) { setMsg({ ok: false, text: r.message, field: r.fieldErrors?.phone ? 'contact' : undefined }); return; }
    setMsg({ ok: true, text: `${r.data?.display ?? contact} is saved as your contact number.` });
    router.refresh();
  });

  // r40 hotfix (the owner, Nov 12: a salesperson "waits for a code and then he never gets it"): once a code is asked for,
  // Resend after 30 seconds, and the number can be kept without a code (calls ring it; it does not sign in)
  const [sentAt, setSentAt] = useState(0);
  const [now, setNow] = useState(0);
  useEffect(() => {
    if (!sentAt) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [sentAt]);
  const wait = sentAt ? Math.max(0, 30 - Math.floor((Math.max(now, sentAt) - sentAt) / 1000)) : 0;
  const ask = (again = false) => start(async () => {
    setMsg(null);
    const r = await requestPhoneCode({ phone: again && sentTo ? sentTo.phone : phone, purpose: 'add' });
    if (!r.ok) { setMsg({ ok: false, text: r.message, field: !again && r.fieldErrors?.phone ? 'phone' : undefined }); return; }
    setSentTo(r.data); setCode(''); setSentAt(Date.now()); setNow(Date.now());
    if (again) setMsg({ ok: true, text: `A new code is on its way to ${r.data.display}. Use the newest text.` });
  });
  const keepWithoutCode = () => start(async () => {
    if (!sentTo) return;
    setMsg(null);
    const r = await saveContactPhone({ phone: sentTo.phone });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setAdding(false); setSentTo(null);
    setMsg({ ok: true, text: `${r.data?.display ?? sentTo.display} is saved as your contact number (not verified): calls from the site ring it. To sign in with it, verify it later with a code.` });
    router.refresh();
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
        <div><dt>Phone</dt><dd data-testid="signin-phone">{state.phone_verified && state.phone ? <>{formatPhone(state.phone)} <span className="badge badge--outline">Verified</span></> : state.phone_on_file ? <>{formatPhone(state.phone_on_file)} (contact number, not verified)</> : 'Not added'}</dd></div>
      </dl>
      {state.email && <ChangeEmail current={state.email} />}
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
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setSentTo(null); setSentAt(0); setMsg(null); }}>Use another number</button></p>
            <div className="stack small" data-testid="phone-no-code">
              <p className="muted">No text yet? Texts can take a minute. Check the number above is your mobile.</p>
              <p className="row" style={{ flexWrap: 'wrap' }}>
                <button className="btn btn--ghost btn--sm" type="button" disabled={pending || wait > 0} onClick={() => ask(true)} data-testid="phone-resend">{wait > 0 ? `Resend the code (${wait}s)` : 'Resend the code'}</button>
                {!state.phone_verified && <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={keepWithoutCode} data-testid="phone-keep-unverified">Save it without a code</button>}
              </p>
              {!state.phone_verified && <p className="muted">Saved without a code, the number is your contact number: calls from the site ring it, but you cannot sign in with it until it is verified.</p>}
            </div>
          </>}
        </form>
      )}

      {!state.phone_verified && (
        <form className="stack" noValidate aria-label="Save a contact number" onSubmit={(e) => { e.preventDefault(); saveContact(); }} data-testid="contact-phone-form">
          <Field id="si-contact" label="Number outside Canada, or the code never arrives? Save it as your contact number" error={err('contact')}
            hint={state.phone_on_file ? `On file: ${formatPhone(state.phone_on_file)} (not verified). Include the country code, for example +63 917 123 4567. No code is texted.` : 'Include the country code, for example +63 917 123 4567. No code is texted; it is used to reach you, not to sign in.'}>
            <input className="input" id="si-contact" name="contact" type="tel" inputMode="tel" autoComplete="tel" value={contact} placeholder="+63 917 123 4567"
              aria-invalid={!!err('contact') || undefined} onChange={(e) => setContact(e.target.value)} data-testid="contact-phone" />
          </Field>
          <p><button className="btn btn--ghost btn--sm" type="submit" disabled={pending} data-testid="contact-phone-save">Save my contact number</button></p>
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
