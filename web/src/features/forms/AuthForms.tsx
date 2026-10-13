'use client';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { requestReset, signIn, signUp, updatePassword } from '@/server/actions/auth';
import { newPasswordSchema, resetSchema, signInSchema, signUpSchema } from './schemas';
import { describedBy, Field } from './Field';
import { Turnstile } from './Turnstile';
import { useForm } from './useForm';

const Err = ({ s }: { s: { ok: boolean; code?: string; message?: string } | null }) =>
  s && !s.ok && s.code !== 'invalid' ? <p className="alert alert--error" role="alert"><span>{s.message}</span></p> : null;

export function SignInForm({ idPrefix = 'si', next }: { idPrefix?: string; next?: string }) {
  const sp = useSearchParams();
  const { state, run, pending, errors: e, clear } = useForm(signInSchema, signIn);
  const n = next ?? sp.get('next') ?? '/account';
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Sign in">
      <Err s={state as never} />
      <input type="hidden" name="next" value={n} />
      <Field id={`${idPrefix}-email`} label="Email" error={e.email}><input className="input" id={`${idPrefix}-email`} name="email" type="email" autoComplete="username" aria-invalid={!!e.email || undefined} aria-describedby={describedBy(`${idPrefix}-email`, e.email)} onInput={() => clear('email')} /></Field>
      <Field id={`${idPrefix}-pass`} label="Password" error={e.password}><input className="input" id={`${idPrefix}-pass`} name="password" type="password" autoComplete="current-password" aria-invalid={!!e.password || undefined} aria-describedby={describedBy(`${idPrefix}-pass`, e.password)} onInput={() => clear('password')} /></Field>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>{pending ? 'Signing in' : 'Sign in'}</button>
      <p className="small"><Link className="link" href="/reset-password">Forgot your password?</Link></p>
    </form>
  );
}

export function SignUpForm({ minAge }: { minAge: string }) {
  const { state, run, pending, errors: e, clear } = useForm(signUpSchema, signUp, (fd) => ({ agree: fd.get('agree') === 'on' }));
  if (state?.ok) {
    const email = (state as { data?: { email?: string } }).data?.email;
    return <div className="alert alert--ok" role="status"><span className="alert__title">Check your email</span><span>We sent a link to {email ?? 'your email address'}. Open it to confirm your account, then sign in. It can take a minute to arrive; check spam if you do not see it.</span></div>;
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

export function ResetForm() {
  const { state, run, pending, errors: e, clear } = useForm(resetSchema, requestReset);
  if (state?.ok) return <div className="alert alert--ok" role="status"><span className="alert__title">Check your email</span><span>If an account uses that address, we sent a link to choose a new password. It works for one hour.</span></div>;
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Reset your password">
      <Err s={state as never} />
      <Field id="rp-email" label="Email" error={e.email}><input className="input" id="rp-email" name="email" type="email" autoComplete="email" aria-invalid={!!e.email || undefined} aria-describedby={describedBy('rp-email', e.email)} onInput={() => clear('email')} /></Field>
      <Turnstile action="password_reset" />
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>Send the link</button>
    </form>
  );
}

export function NewPasswordForm() {
  const sp = useSearchParams();
  const { state, run, pending, errors: e, clear } = useForm(newPasswordSchema, updatePassword);
  return (
    <form className="stack-lg" onSubmit={run} noValidate aria-label="Choose a new password">
      <Err s={state as never} />
      {sp.get('token') && <input type="hidden" name="token" value={sp.get('token')!} />}
      <Field id="np-pass" label="New password" error={e.password} hint="At least 8 characters."><input className="input" id="np-pass" name="password" type="password" autoComplete="new-password" aria-invalid={!!e.password || undefined} aria-describedby={describedBy('np-pass', e.password, true)} onInput={() => clear('password')} /></Field>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending}>Save the new password</button>
    </form>
  );
}
