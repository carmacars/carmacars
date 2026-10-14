'use client';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { useRef, useState, useTransition } from 'react';
import { requestReset, resendConfirmation, signIn, signUp, updatePassword } from '@/server/actions/auth';
import { newPasswordSchema, resetSchema, signInSchema, signUpSchema } from './schemas';
import { describedBy, Field } from './Field';
import { Turnstile } from './Turnstile';
import { useForm } from './useForm';

const Err = ({ s }: { s: { ok: boolean; code?: string; message?: string } | null }) =>
  s && !s.ok && s.code !== 'invalid' ? <p className="alert alert--error" role="alert"><span>{s.message}</span></p> : null;

export function SignInForm({ idPrefix = 'si', next }: { idPrefix?: string; next?: string }) {
  const sp = useSearchParams();
  const { state, run, pending, errors: e, clear } = useForm(signInSchema, signIn);
  const n = next ?? sp.get('next') ?? '';
  const email = useRef<HTMLInputElement>(null);
  const code = state && !state.ok ? state.code : null;
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Sign in">
      {sp.get('error') === 'link' && !state && <p className="alert alert--error" role="alert"><span>That link has expired or was already used. <Link className="link" href="/reset-password">Ask for a new one</Link>.</span></p>}
      <Err s={state as never} />
      {code === 'credentials' && <p className="small muted" data-testid="signin-hint">Invited by CarmaCars and never chose a password, or forgot it? <Link className="link" href="/reset-password">Set a new password</Link> by email.</p>}
      {code === 'unconfirmed' && <ResendConfirmation email={() => email.current?.value ?? ''} />}
      <input type="hidden" name="next" value={n} />
      <Field id={`${idPrefix}-email`} label="Email" error={e.email}><input ref={email} className="input" id={`${idPrefix}-email`} name="email" type="email" autoComplete="username" aria-invalid={!!e.email || undefined} aria-describedby={describedBy(`${idPrefix}-email`, e.email)} onInput={() => clear('email')} /></Field>
      <Field id={`${idPrefix}-pass`} label="Password" error={e.password}><input className="input" id={`${idPrefix}-pass`} name="password" type="password" autoComplete="current-password" aria-invalid={!!e.password || undefined} aria-describedby={describedBy(`${idPrefix}-pass`, e.password)} onInput={() => clear('password')} /></Field>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Signing in' : 'Sign in'}</button>
      <p className="small"><Link className="link" href="/reset-password">Forgot your password?</Link></p>
    </form>
  );
}

function ResendConfirmation({ email }: { email: () => string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (
    <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-3)', alignItems: 'center' }}>
      <button className="btn btn--ghost btn--sm" type="button" data-testid="resend-confirmation" disabled={pending}
        onClick={() => start(async () => { const r = await resendConfirmation(email()); setMsg(r.ok ? { ok: true, text: 'If that address has an account waiting to be confirmed, we sent the link again. Check your inbox and spam.' } : { ok: false, text: r.message }); })}>
        {pending ? 'Sending' : 'Send the confirmation link again'}</button>
      {msg && <span className={msg.ok ? 'small' : 'small error'} role="status">{msg.text}</span>}
    </div>
  );
}

export function SignUpForm({ minAge }: { minAge: string }) {
  const { state, run, pending, errors: e, clear } = useForm(signUpSchema, signUp, (fd) => ({ agree: fd.get('agree') === 'on' }));
  if (state?.ok) {
    const email = (state as { data?: { email?: string } }).data?.email;
    const onRecord = (state as { data?: { onRecord?: boolean } }).data?.onRecord;
    return <div className="alert alert--ok" role="status"><span className="alert__title">Check your email</span><span>{onRecord
      ? <>We already have a booking request from {email ?? 'this address'}. We sent a link there: open it to choose your password and see your bookings. The link works for one hour.</>
      : <>We sent a link to {email ?? 'your email address'}. Open it to confirm your account, then sign in. It can take a minute to arrive; check spam if you do not see it.</>}</span></div>;
  }
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Create an account">
      <Err s={state as never} />
      <Field id="su-name" label="Full name" error={e.name}><input className="input" id="su-name" name="name" autoComplete="name" aria-invalid={!!e.name || undefined} aria-describedby={describedBy('su-name', e.name)} onInput={() => clear('name')} /></Field>
      <Field id="su-email" label="Email" error={e.email}><input className="input" id="su-email" name="email" type="email" autoComplete="email" aria-invalid={!!e.email || undefined} aria-describedby={describedBy('su-email', e.email)} onInput={() => clear('email')} /></Field>
      <Field id="su-pass" label="Password" error={e.password} hint="At least 8 characters."><input className="input" id="su-pass" name="password" type="password" autoComplete="new-password" aria-invalid={!!e.password || undefined} aria-describedby={describedBy('su-pass', e.password, true)} onInput={() => clear('password')} /></Field>
      <div className={`field${e.agree ? ' has-error' : ''}`}>
        <label className="check"><input type="checkbox" name="agree" aria-invalid={!!e.agree || undefined} aria-describedby={e.agree ? 'su-agree-err' : undefined} onChange={() => clear('agree')} /><span className="small">I am {minAge} or older and agree to the <Link className="link" href="/terms">Terms of use</Link> and <Link className="link" href="/privacy">Privacy policy</Link>.</span></label>
        <p className="error" role="alert" id="su-agree-err">{e.agree ?? ''}</p>
      </div>
      <Turnstile action="sign_up" />
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Creating your account' : 'Create account'}</button>
    </form>
  );
}

export function ResetForm({ email, label = 'Send the link', idPrefix = 'rp' }: { email?: string; label?: string; idPrefix?: string }) {
  const { state, run, pending, errors: e, clear } = useForm(resetSchema, requestReset);
  if (state?.ok) return <div className="alert alert--ok" role="status"><span className="alert__title">Check your email</span><span>If an account uses that address, we sent a link to choose a new password. It works for one hour. Check spam if you do not see it within a few minutes.</span></div>;
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Reset your password">
      <Err s={state as never} />
      <Field id={`${idPrefix}-email`} label="Email" error={e.email}><input className="input" id={`${idPrefix}-email`} name="email" type="email" autoComplete="email" defaultValue={email} aria-invalid={!!e.email || undefined} aria-describedby={describedBy(`${idPrefix}-email`, e.email)} onInput={() => clear('email')} /></Field>
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
      <Field id="np-pass" label="New password" error={e.password} hint="At least 8 characters."><input className="input" id="np-pass" name="password" type="password" autoComplete="new-password" aria-invalid={!!e.password || undefined} aria-describedby={describedBy('np-pass', e.password, true)} onInput={() => clear('password')} /></Field>
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
    <form className="stack-lg" aria-label="Send the confirmation link again" onSubmit={(e) => { e.preventDefault(); start(async () => { const r = await resendConfirmation(ref.current?.value ?? ''); setMsg(r.ok ? { ok: true, text: 'If that address has an account waiting to be confirmed, we sent a new link. It works for one hour.' } : { ok: false, text: r.message }); }); }}>
      {msg && !msg.ok && <p className="alert alert--error" role="alert"><span>{msg.text}</span></p>}
      <Field id="rc-email" label="Email"><input ref={ref} className="input" id="rc-email" name="email" type="email" autoComplete="email" defaultValue={email} /></Field>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Sending' : 'Send me a new link'}</button>
    </form>
  );
}
