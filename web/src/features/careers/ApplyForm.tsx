'use client';
import Link from 'next/link';
import { useEffect, useRef, useState, type FormEvent } from 'react';
import { submitApplication, type ApplyResult } from '@/server/actions/careers';
import { describedBy, Field } from '@/features/forms/Field';
import { Turnstile } from '@/features/forms/Turnstile';
import { OUTCOME_WORDS, type Question, type RolePublic } from './model';

// The screening form of one role (migration 0173): contact details, then the role's questions, one column, about five minutes.
// What is typed is kept on this device as it is typed (localStorage, never sent until Send) and restored on return. The
// database checks and scores every answer; the browser never sees the points.
type Answers = Record<string, string | string[]>;
interface Draft { full_name: string; email: string; phone: string; profile_name: string; answers: Answers }
const EMPTY: Draft = { full_name: '', email: '', phone: '', profile_name: '', answers: {} };

export function ApplyForm({ role, src, utm, prefill, refToken }: { role: RolePublic; src: string | null; utm: Record<string, string>;
  prefill?: { full_name: string; email: string; phone: string; from_role: string } | null; refToken?: string | null }) {
  const KEY = `cc-apply-${role.slug}`;
  const [d, setD] = useState<Draft>(EMPTY);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [done, setDone] = useState<Extract<ApplyResult, { ok: true }> | null>(null);
  const loaded = useRef(false);
  const formRef = useRef<HTMLFormElement>(null);

  useEffect(() => {
    let draft: Draft | null = null;
    try { draft = JSON.parse(localStorage.getItem(KEY) ?? 'null') as Draft | null; } catch { draft = null; }
    const base = draft && typeof draft === 'object' ? { ...EMPTY, ...draft, answers: draft.answers ?? {} } : EMPTY;
    // a referral link fills in the contact details (they win over an older draft)
    setD(prefill ? { ...base, full_name: prefill.full_name, email: prefill.email ?? '', phone: prefill.phone ?? '' } : base);
    loaded.current = true;
  }, [KEY, prefill]);
  useEffect(() => {
    if (!loaded.current) return;
    try { localStorage.setItem(KEY, JSON.stringify(d)); setSaved(true); } catch { /* private mode */ }
  }, [KEY, d]);

  const set = (k: keyof Omit<Draft, 'answers'>, v: string) => { setD((x) => ({ ...x, [k]: v })); clear(k); };
  const answer = (k: string, v: string | string[]) => { setD((x) => ({ ...x, answers: { ...x.answers, [k]: v } })); clear(k); };
  const clear = (k: string) => setErrors((e) => { if (!e[k]) return e; const n = { ...e }; delete n[k]; return n; });

  function check(): Record<string, string> {
    const e: Record<string, string> = {};
    if (d.full_name.trim().length < 2) e.full_name = 'Enter your full name.';
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(d.email.trim())) e.email = 'Enter a full email address, for example name@example.com.';
    if (d.phone.replace(/\D/g, '').length < 7) e.phone = 'Enter a phone number we can call.';
    for (const q of role.questions) {
      const a = d.answers[q.key];
      const empty = Array.isArray(a) ? a.length === 0 : !String(a ?? '').trim();
      if (q.required && empty) e[q.key] = q.type === 'single' ? 'Choose one.' : q.type === 'multi' ? 'Choose at least one.' : q.type === 'date' ? 'Enter a date.' : 'Please answer this one.';
    }
    return e;
  }
  const focusFirst = () => requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus());

  async function submit(ev: FormEvent<HTMLFormElement>) {
    ev.preventDefault();
    setMessage(null);
    const e = check();
    setErrors(e);
    if (Object.keys(e).length) { setMessage('Check the highlighted answers.'); focusFirst(); return; }
    setBusy(true);
    const fd = new FormData(ev.currentTarget);
    const r = await submitApplication({ role: role.slug, full_name: d.full_name, email: d.email, phone: d.phone, profile_name: d.profile_name, answers: d.answers, src, utm,
      ref: refToken ?? null, turnstile: (fd.get('cf-turnstile-response') as string | null) ?? null, website: String(fd.get('website') ?? '') });
    setBusy(false);
    if (!r.ok) { setErrors(r.errors ?? {}); setMessage(r.message); if (r.errors) focusFirst(); return; }
    try { localStorage.removeItem(KEY); } catch { /* private mode */ }
    setDone(r);
    requestAnimationFrame(() => { window.scrollTo({ top: 0 }); document.getElementById('apply-done')?.focus(); });
  }

  if (done) {
    const w = OUTCOME_WORDS[done.outcome] ?? OUTCOME_WORDS.received!;
    return (
      <section className="stack-lg cr-done" id="apply-done" tabIndex={-1} aria-labelledby="apply-done-h" data-testid="apply-done" data-outcome={done.outcome}>
        <h2 className="d2" id="apply-done-h">{w.h}</h2>
        <p className="lead">{w.p}</p>
        {done.outcome === 'invited' && done.token && <p><Link prefetch={false} className="btn btn--primary btn--lg" href={`/careers/book/${done.token}`} data-testid="apply-book">Book my interview call</Link></p>}
        {done.outcome === 'referred' && done.other_role && <p><Link prefetch={false} className="btn btn--primary btn--lg" href={`/careers/${done.other_role}/apply?src=referral${done.token ? `&ref=${done.token}` : ''}`} data-testid="apply-referred">Apply for {done.other_title ?? 'the other role'}</Link></p>}
        <p className="small muted">We also sent this to {d.email}. Not there? Check your spam folder.</p>
        <p><Link prefetch={false} className="link" href="/careers">See all open roles</Link></p>
      </section>
    );
  }

  const input = (k: 'full_name' | 'email' | 'phone' | 'profile_name', label: string, type: string, auto: string, opt = false, hint?: string) => (
    <Field id={`ap-${k}`} label={label} optional={opt} error={errors[k]} hint={hint}>
      <input className="input" id={`ap-${k}`} name={k} type={type} autoComplete={auto} value={d[k]} onChange={(e) => set(k, e.target.value)}
        aria-invalid={!!errors[k] || undefined} aria-describedby={describedBy(`ap-${k}`, errors[k], !!hint)} data-testid={`ap-${k}`} />
    </Field>
  );
  return (
    <form ref={formRef} className="stack-lg cr-form" noValidate onSubmit={submit} aria-labelledby="ap-h" data-testid="apply-form">
      <h2 className="d3" id="ap-h">Your application</h2>
      {prefill && <p className="alert" data-testid="apply-prefilled"><span>Your details are filled in from your {prefill.from_role} application. Check them, then answer the questions for this role.</span></p>}
      {message && <p className="alert alert--error" role="alert" data-testid="apply-error"><span>{message}</span></p>}
      <fieldset className="stack cr-group">
        <legend className="d4">About you</legend>
        {input('full_name', 'Full name', 'text', 'name')}
        {input('email', 'Email', 'email', 'email')}
        {input('phone', 'Mobile number', 'tel', 'tel', false, 'We call or text this number about your application.')}
        {input('profile_name', src === 'onlinejobs' ? 'Name on your OnlineJobs.ph profile, if different' : 'Name on your Indeed profile, if different', 'text', 'off', true)}
      </fieldset>
      <fieldset className="stack-lg cr-group">
        <legend className="d4">About the role</legend>
        {role.questions.map((q, n) => <QuestionField key={q.key} q={q} n={n + 1} value={d.answers[q.key]} error={errors[q.key]} onChange={(v) => answer(q.key, v)} />)}
      </fieldset>
      <div className="cr-hp" aria-hidden="true"><label htmlFor="ap-website">Website</label><input id="ap-website" name="website" tabIndex={-1} autoComplete="off" /></div>
      <Turnstile action="job_apply" />
      <button className="btn btn--primary btn--lg" type="submit" disabled={busy} data-testid="ap-submit">{busy ? 'Sending' : 'Send my application'}</button>
      <p className="small muted" aria-live="polite">{saved ? 'Saved on this device as you type. ' : ''}We use your answers only to assess your application; see our <Link className="link" href="/privacy">Privacy policy</Link>.</p>
    </form>
  );
}

function QuestionField({ q, n, value, error, onChange }: { q: Question; n: number; value: string | string[] | undefined; error?: string; onChange: (v: string | string[]) => void }) {
  const id = `ap-q-${q.key}`;
  const label = <>{n}. {q.label}</>;
  if (q.type === 'single' || q.type === 'multi') {
    const multi = q.type === 'multi';
    const sel = Array.isArray(value) ? value : value ? [value] : [];
    return (
      <fieldset className={`field cr-q${error ? ' has-error' : ''}`} aria-describedby={describedBy(id, error, !!q.hint)} data-testid={`q-${q.key}`}>
        <legend className="label">{label}{!q.required && <> <span className="opt">optional</span></>}</legend>
        {q.hint && <p className="hint" id={`${id}-hint`}>{q.hint}</p>}
        <div className={`cr-choices${(q.choices ?? []).every((c) => c.length < 14) ? ' cr-choices--short' : ''}`}>
          {(q.choices ?? []).map((c, i) => (
            <label key={c} className={multi ? 'check' : 'radio'}>
              <input type={multi ? 'checkbox' : 'radio'} name={id} value={c} checked={sel.includes(c)} aria-invalid={(!!error && i === 0) || undefined}
                onChange={(e) => onChange(multi ? (e.target.checked ? [...sel, c] : sel.filter((x) => x !== c)) : c)} />
              <span>{c}</span>
            </label>
          ))}
        </div>
        <p className="error" role="alert" id={`${id}-err`}>{error ?? ''}</p>
      </fieldset>
    );
  }
  const v = typeof value === 'string' ? value : '';
  return (
    <Field id={id} label={label} optional={!q.required} error={error} hint={q.hint}>
      {q.type === 'para'
        ? <textarea className="textarea" id={id} rows={4} maxLength={2000} value={v} onChange={(e) => onChange(e.target.value)} aria-invalid={!!error || undefined} aria-describedby={describedBy(id, error, !!q.hint)} data-testid={`q-${q.key}`} />
        : <input className="input" id={id} type={q.type === 'date' ? 'date' : 'text'} maxLength={300} placeholder={q.placeholder} value={v} onChange={(e) => onChange(e.target.value)}
            aria-invalid={!!error || undefined} aria-describedby={describedBy(id, error, !!q.hint)} data-testid={`q-${q.key}`} />}
    </Field>
  );
}
