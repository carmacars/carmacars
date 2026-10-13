'use client';
import { useState, useTransition } from 'react';
import { startTwoStep, verifyTwoStep } from '@/server/actions/auth';

// Two-step sign-in with an authenticator app (Supabase Auth TOTP). Setup: start, add the key to the app,
// type the code it shows. Sign-in: type the code.
export function TwoStepCode({ next, factorId, label = 'Continue' }: { next: string | null; factorId?: string | null; label?: string }) {
  const [code, setCode] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); setErr(null); start(async () => { const r = await verifyTwoStep(factorId ?? null, code, next); if (r && !r.ok) setErr(r.message); }); }}>
      <div className="field"><label className="label" htmlFor="ts-code">6-digit code from the app</label>
        <input className="input" id="ts-code" name="code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code} onChange={(e) => setCode(e.target.value)} aria-invalid={err ? true : undefined} aria-describedby={err ? 'ts-err' : undefined} data-testid="totp-code" /></div>
      {err && <p className="alert alert--error" role="alert" id="ts-err"><span>{err}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={pending} data-testid="totp-submit">{pending ? 'Checking' : label}</button>
    </form>
  );
}

export function TwoStepSetup({ next }: { next: string | null }) {
  const [f, setF] = useState<{ factorId: string; secret: string; uri: string; qr: string | null } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  if (!f) return (
    <div className="stack">
      <button className="btn btn--primary" type="button" disabled={pending} data-testid="totp-start" onClick={() => start(async () => { const r = await startTwoStep(); if (r.ok) setF(r.data); else setErr(r.message); })}>{pending ? 'Starting' : 'Set up an authenticator app'}</button>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
  return (
    <div className="stack">
      <p>In your authenticator app, add an account {f.qr ? 'by scanning this code or ' : ''}by typing this key:</p>
      {/* eslint-disable-next-line @next/next/no-img-element -- the QR code Supabase returns as a data URL */}
      {f.qr && <img src={f.qr} alt="QR code for the authenticator app" width={180} height={180} />}
      <p className="pt-mono" data-testid="totp-secret" style={{ wordBreak: 'break-all' }}>{f.secret}</p>
      <p className="small"><a className="link" href={f.uri}>Open in an authenticator app on this device</a></p>
      <TwoStepCode next={next} factorId={f.factorId} label="Turn on two-step sign-in" />
    </div>
  );
}
