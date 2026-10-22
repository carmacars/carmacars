'use client';
import { PasswordInput } from './PasswordInput';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { useRef, useState, useSyncExternalStore, useTransition } from 'react';
import { requestReset, resendConfirmation, signIn, signUp, updatePassword } from '@/server/actions/auth';
import { newPasswordSchema, resetSchema, signInSchema, signUpSchema } from './schemas';
import { describedBy, Field } from './Field';
import { Turnstile } from './Turnstile';
import { useForm } from './useForm';
import { PhoneSignInForm } from './PhoneSignIn';

/** The sign-in this device used last (cc-signin, set at sign-in and from the profile page), or ?method=phone. */
const noSubscribe = () => () => undefined;
function useMethod(initial: string | null): ['email' | 'phone', (m: 'email' | 'phone') => void] {
  const cookiePhone = useSyncExternalStore(noSubscribe, () => /(?:^|;\s*)cc-signin=phone(?:;|$)/.test(document.cookie), () => false);
  const [chosen, setChosen] = useState<'email' | 'phone' | null>(initial === 'phone' || initial === 'email' ? initial : null);
  return [chosen ?? (cookiePhone ? 'phone' : 'email'), setChosen];
}

const Err = ({ s }: { s: { ok: boolean; code?: string; message?: string } | null }) =>
  s && !s.ok && s.code !== 'invalid' ? <p className="alert alert--error" role="alert"><span>{s.message}</span></p> : null;

export function SignInForm({ idPrefix = 'si', next }: { idPrefix?: string; next?: string }) {
  const sp = useSearchParams();
  const [method, setMethod] = useMethod(sp.get('method'));
  if (method === 'phone') return <PhoneSignInForm next={next ?? sp.get('next') ?? ''} onUseEmail={() => setMethod('email')} idPrefix={`${idPrefix}-ph`} />;
  return <EmailSignInForm idPrefix={idPrefix} next={next} onUsePhone={() => setMethod('phone')} />;
}

function EmailSignInForm({ idPrefix, next, onUsePhone }: { idPrefix: string; next?: string; onUsePhone: () => void }) {
  const sp = useSearchParams();
  const { state, run, pending, errors: e, clear } = useForm(signInSchema, signIn);
  const n = next ?? sp.get('next') ?? '';
  const email = useRef<HTMLInputElement>(null);
  const code = state && !state.ok ? state.code : null;
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Sign in">
      {sp.get('error') === 'link' && !state && <p className="alert alert--error" role="alert"><span>That link has expired or was already used. <Link className="link" href="/reset-password">Ask for a new one</Link>.</span></p>}
      {code !== 'unconfirmed' && <Err s={state as never} />}
      {code === 'unconfirmed' && <div className="alert alert--error" role="alert" data-testid="signin-unconfirmed"><span className="alert__title">Confirm your email first</span><span>We emailed you a link when the account was made (subject &quot;Confirm your CarmaCars account&quot;). Links work for 24 hours. Press the button for a new one, then open it: it signs you in.</span></div>}
      {code === 'credentials' && <p className="small muted" data-testid="signin-hint">Invited by CarmaCars and never chose a password, or forgot it? <Link className="link" href="/reset-password">Set a new password</Link> by email.</p>}
      {code === 'unconfirmed' && <ResendConfirmation email={() => email.current?.value ?? ''} />}
      <input type="hidden" name="next" value={n} />
      <Field float id={`${idPrefix}-email`} label="Email" error={e.email}><input ref={email} className="input" placeholder=" " id={`${idPrefix}-email`} name="email" type="email" autoComplete="username" aria-invalid={!!e.email || undefined} aria-describedby={describedBy(`${idPrefix}-email`, e.email)} onInput={() => clear('email')} /></Field>
      <Field float id={`${idPrefix}-pass`} label="Password" error={e.password}><PasswordInput className="input" placeholder=" " id={`${idPrefix}-pass`} name="password" autoComplete="current-password" aria-invalid={!!e.password || undefined} aria-describedby={describedBy(`${idPrefix}-pass`, e.password)} onInput={() => clear('password')} /></Field>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Signing in' : 'Sign in'}</button>
      <p className="row small" style={{ flexWrap: 'wrap', gap: 'var(--s-4)' }}><Link className="link" href="/reset-password">Forgot your password?</Link>
        <button type="button" className="link" onClick={onUsePhone} data-testid="use-phone">Use my phone number instead</button></p>
    </form>
  );
}

function ResendConfirmation({ email }: { email: () => string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (
    <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-3)', alignItems: 'center' }}>
      <button className="btn btn--primary" type="button" data-testid="resend-confirmation" disabled={pending}
        onClick={() => start(async () => { const r = await resendConfirmation(email()); setMsg(r.ok ? { ok: true, text: 'If that address has an account waiting to be confirmed, we sent a new link. It works for 24 hours. Check your inbox and spam.' } : { ok: false, text: r.message }); })}>
        {pending ? 'Sending' : 'Send a new confirmation link'}</button>
      {msg && <span className={msg.ok ? 'small' : 'small error'} role="status">{msg.text}</span>}
    </div>
  );
}

export function SignUpForm({ minAge }: { minAge: string }) {
  const sp = useSearchParams();
  const [method, setMethod] = useState<'email' | 'phone'>(sp.get('method') === 'phone' ? 'phone' : 'email');
  if (method === 'phone') return <PhoneSignInForm signUp minAge={minAge} next={sp.get('next') ?? ''} onUseEmail={() => setMethod('email')} idPrefix="su-ph" />;
  return <EmailSignUpForm minAge={minAge} onUsePhone={() => setMethod('phone')} />;
}

function EmailSignUpForm({ minAge, onUsePhone }: { minAge: string; onUsePhone: () => void }) {
  const { state, run, pending, errors: e, clear } = useForm(signUpSchema, signUp, (fd) => ({ agree: fd.get('agree') === 'on' }));
  if (state?.ok) {
    const email = (state as { data?: { email?: string } }).data?.email;
    const onRecord = (state as { data?: { onRecord?: boolean } }).data?.onRecord;
    return <div className="alert alert--ok" role="status"><span className="alert__title">Check your email</span><span>{onRecord
      ? <>We already have a booking request from {email ?? 'this address'}. We sent a link there: open it to choose your password and see your bookings. The link works for 24 hours.</>
      : <>We sent a link to {email ?? 'your email address'} with the subject &quot;Confirm your CarmaCars account&quot;. Open it within 24 hours to confirm your email: it signs you in. It can take a minute to arrive; check spam if you do not see it.</>}</span></div>;
  }
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Create an account">
      <Err s={state as never} />
      <Field float id="su-name" label="Full name" error={e.name}><input className="input" placeholder=" " id="su-name" name="name" autoComplete="name" aria-invalid={!!e.name || undefined} aria-describedby={describedBy('su-name', e.name)} onInput={() => clear('name')} /></Field>
      <Field float id="su-email" label="Email" error={e.email}><input className="input" placeholder=" " id="su-email" name="email" type="email" autoComplete="email" aria-invalid={!!e.email || undefined} aria-describedby={describedBy('su-email', e.email)} onInput={() => clear('email')} /></Field>
      <Field float id="su-pass" label="Password" error={e.password} hint="At least 8 characters."><PasswordInput className="input" placeholder=" " id="su-pass" name="password" autoComplete="new-password" aria-invalid={!!e.password || undefined} aria-describedby={describedBy('su-pass', e.password, true)} onInput={() => clear('password')} /></Field>
      <div className={`field${e.agree ? ' has-error' : ''}`}>
        <label className="check"><input type="checkbox" name="agree" aria-invalid={!!e.agree || undefined} aria-describedby={e.agree ? 'su-agree-err' : undefined} onChange={() => clear('agree')} /><span className="small">I am {minAge} or older and agree to the <Link className="link" href="/terms">Terms of use</Link> and <Link className="link" href="/privacy">Privacy policy</Link>.</span></label>
        <p className="error" role="alert" id="su-agree-err">{e.agree ?? ''}</p>
      </div>
      <Turnstile action="sign_up" />
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Creating your account' : 'Create account'}</button>
      <p className="small"><button type="button" className="link" onClick={onUsePhone} data-testid="use-phone">Sign up with my phone number instead</button></p>
    </form>
  );
}

export function ResetForm({ email, label = 'Send the link', idPrefix = 'rp' }: { email?: string; label?: string; idPrefix?: string }) {
  const { state, run, pending, errors: e, clear } = useForm(resetSchema, requestReset);
  if (state?.ok) return <div className="alert alert--ok" role="status"><span className="alert__title">Check your email</span><span>If an account uses that address, we sent a link to choose a new password. It works for 24 hours. Check spam if you do not see it within a few minutes.</span></div>;
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Reset your password">
      <Err s={state as never} />
      <Field float id={`${idPrefix}-email`} label="Email" error={e.email}><input className="input" placeholder=" " id={`${idPrefix}-email`} name="email" type="email" autoComplete="email" defaultValue={email} aria-invalid={!!e.email || undefined} aria-describedby={describedBy(`${idPrefix}-email`, e.email)} onInput={() => clear('email')} /></Field>
      <Turnstile action="password_reset" />
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Sending' : label}</button>
    </form>
  );
}

export function NewPasswordForm() {
  const sp = useSearchParams();
  const { state, run, pending, errors: e, clear } = useForm(newPasswordSchema, updatePassword);
  if (state && !state.ok && state.code === 'expired') {
    return (
      <div className="stack-lg">
        <p className="alert alert--error" role="alert"><span>{state.message}</span></p>
        <ResetForm label="Send me a new link" idPrefix="np-rp" />
      </div>
    );
  }
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Choose a new password">
      <Err s={state as never} />
      {sp.get('token') && <input type="hidden" name="token" value={sp.get('token')!} />}
      <Field float id="np-pass" label="New password" error={e.password} hint="At least 8 characters."><PasswordInput className="input" placeholder=" " id="np-pass" name="password" autoComplete="new-password" aria-invalid={!!e.password || undefined} aria-describedby={describedBy('np-pass', e.password, true)} onInput={() => clear('password')} /></Field>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Saving' : 'Save the new password'}</button>
    </form>
  );
}

/** The "confirm your email" link again, for the link-expired page. */
export function ResendConfirmForm({ email }: { email?: string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const ref = useRef<HTMLInputElement>(null);
  if (msg?.ok) return <div className="alert alert--ok" role="status"><span className="alert__title">Check your email</span><span>{msg.text}</span></div>;
  return (
    <form className="stack-lg" aria-label="Send the confirmation link again" onSubmit={(e) => { e.preventDefault(); start(async () => { const r = await resendConfirmation(ref.current?.value ?? ''); setMsg(r.ok ? { ok: true, text: 'If that address has an account waiting to be confirmed, we sent a new link. It works for 24 hours. Check spam if you do not see it within a few minutes.' } : { ok: false, text: r.message }); }); }}>
      {msg && !msg.ok && <p className="alert alert--error" role="alert"><span>{msg.text}</span></p>}
      <Field float id="rc-email" label="Email"><input ref={ref} className="input" placeholder=" " id="rc-email" name="email" type="email" autoComplete="email" defaultValue={email} /></Field>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Sending' : 'Send a new confirmation link'}</button>
    </form>
  );
}
