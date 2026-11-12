'use client';
import Link from '@/components/Link';
import { useEffect, useRef, useState, type FormEvent } from 'react';
import { submitApplication, type ApplyResult } from '@/server/actions/careers';
import { DateInput } from '@/components/DateInput';
import { describedBy, Field } from '@/features/forms/Field';
import { TURNSTILE_FAILED, Turnstile, freshTurnstileToken } from '@/features/forms/Turnstile';
import { OUTCOME_WORDS, payOver, type Question, type RolePublic } from './model';

// The screening form of one role (migration 0173): contact details, then the role's questions, one column, about five minutes.
// What is typed is kept on this device as it is typed (localStorage, never sent until Send) and restored on return. The
// database checks and scores every answer; the browser never sees the points.
type Answers = Record<string, string | string[]>;
interface Draft { full_name: string; email: string; phone: string; profile_name: string; city: string; region: string; country: string; answers: Answers }
const EMPTY: Draft = { full_name: '', email: '', phone: '', profile_name: '', city: '', region: '', country: 'CA', answers: {} };
// 1067: an in-person role asks where the applicant lives (city, province or state, country); outside the Toronto area they
// are told and sent to Remote Sales with their details. Only these fields (and the country of the phone and the connection) are used.
const COUNTRIES: Array<[string, string]> = [['CA', 'Canada'], ['US', 'United States'], ['PH', 'Philippines'], ['IN', 'India'], ['PK', 'Pakistan'], ['MX', 'Mexico'], ['GB', 'United Kingdom'], ['ZZ', 'Another country']];

export function ApplyForm({ role, src, utm, prefill, refToken }: { role: RolePublic; src: string | null; utm: Record<string, string>;
  prefill?: { full_name: string; email: string; phone: string; from_role: string } | null; refToken?: string | null }) {
  const KEY = `cc-apply-${role.slug}`;
  const [d, setD] = useState<Draft>(EMPTY);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [done, setDone] = useState<Extract<ApplyResult, { ok: true }> | null>(null);
  const [away, setAway] = useState<{ slug: string | null; title: string | null } | null>(null);
  const [payNote, setPayNote] = useState<null | 'over' | 'no'>(null);
  const payAcked = useRef(false);
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
  const answer = (k: string, v: string | string[]) => {
    setD((x) => ({ ...x, answers: { ...x.answers, [k]: v } })); clear(k);
    if (k === 'pay' && payQ?.type === 'single' && v === payQ.choices?.find((c) => c !== payYes)) setPayNote('no');
  };
  // the pay of the role is fixed: a higher figure, or a no to the pay, opens a note with the pay and the choices (once)
  const payQ = role.questions.find((q) => q.key === 'pay');
  const payYes = payQ?.choices?.find((c) => /^yes/i.test(c));
  const payMax = role.pay_max_cents ?? role.pay_min_cents;
  const askedOver = () => payQ?.type === 'text' && payOver(String(d.answers.pay ?? ''), payMax);
  const checkPay = () => { if (!payAcked.current && askedOver()) setPayNote('over'); };
  const clear = (k: string) => setErrors((e) => { if (!e[k]) return e; const n = { ...e }; delete n[k]; return n; });

  function check(): Record<string, string> {
    const e: Record<string, string> = {};
    if (d.full_name.trim().length < 2) e.full_name = 'Enter your full name.';
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(d.email.trim())) e.email = 'Enter a full email address, for example name@example.com.';
    if (d.phone.replace(/\D/g, '').length < 7) e.phone = 'Enter a phone number we can call.';
    if (!role.remote && d.city.trim().length < 2) e.city = 'Enter the city or town you live in.';
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
    if (!payAcked.current && askedOver()) { setPayNote('over'); return; }
    setBusy(true);
    const form = ev.currentTarget;
    const fd = new FormData(form);
    // r40: a fresh token at Send (the widget is reset; one taken at load expires); no token gives a clear message, never a crash
    const token = await freshTurnstileToken(form).catch(() => null) ?? ((fd.get('cf-turnstile-response') as string | null) || null);
    if (!token) { setBusy(false); setMessage(TURNSTILE_FAILED); return; }
    let r: ApplyResult;
    try {
      r = await submitApplication({ role: role.slug, full_name: d.full_name, email: d.email, phone: d.phone, profile_name: d.profile_name, answers: d.answers, src, utm,
        location: role.remote ? undefined : { city: d.city, region: d.region, country: d.country },
        ref: refToken ?? null, turnstile: token, website: String(fd.get('website') ?? '') });
    } catch { setBusy(false); setMessage('Your answers did not send: check your connection and press Send again. They are kept on this device.'); return; }
    setBusy(false);
    if (!r.ok && r.code === 'outside_area') { setAway({ slug: r.remote_slug ?? null, title: r.remote_title ?? null }); requestAnimationFrame(() => document.getElementById('apply-away')?.focus()); return; }
    if (!r.ok) { setErrors(r.errors ?? {}); setMessage(r.message); if (r.errors) focusFirst(); return; }
    try { localStorage.removeItem(KEY); } catch { /* private mode */ }
    setDone(r);
    requestAnimationFrame(() => { window.scrollTo({ top: 0 }); document.getElementById('apply-done')?.focus(); });
  }

  if (away) {
    const q = new URLSearchParams({ src: 'referral', name: d.full_name, email: d.email });
    return (
      <section className="stack-lg cr-done" id="apply-away" tabIndex={-1} aria-labelledby="apply-away-h" data-testid="apply-away">
        <h2 className="d2" id="apply-away-h">This role is in person in the Toronto area</h2>
        <p className="lead">You live outside the area we work in, so we cannot take this in-person application. {away.slug ? `${away.title ?? 'Remote Sales'} is open from anywhere, and your details carry over.` : 'Please look at our remote roles.'}</p>
        {away.slug && <p><Link prefetch={false} className="btn btn--primary btn--lg" href={`/careers/${away.slug}/apply?${q.toString()}`} data-testid="apply-away-remote">Apply for {away.title ?? 'Remote Sales'}</Link></p>}
        <p><Link prefetch={false} className="link" href="/careers">See all open roles</Link></p>
      </section>
    );
  }

  if (done) {
    const w = (done.outcome === 'invited' && done.ai_interview ? OUTCOME_WORDS.interview : OUTCOME_WORDS[done.outcome]) ?? OUTCOME_WORDS.received!;
    return (
      <section className="stack-lg cr-done" id="apply-done" tabIndex={-1} aria-labelledby="apply-done-h" data-testid="apply-done" data-outcome={done.outcome}>
        <h2 className="d2" id="apply-done-h">{w.h}</h2>
        <p className="lead">{w.p}</p>
        {done.outcome === 'invited' && done.token && (done.ai_interview
          ? <p><Link prefetch={false} className="btn btn--primary btn--lg" href={`/careers/interview/${done.token}`} data-testid="apply-interview">Start my interview</Link></p>
          : <p><Link prefetch={false} className="btn btn--primary btn--lg" href={`/careers/book/${done.token}`} data-testid="apply-book">Book my interview call</Link></p>)}
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
        {!role.remote && <fieldset className="stack" data-testid="ap-location"><legend className="label">Where you live (this role is in person in the Toronto area)</legend>
          <Field id="ap-city" label="City or town" error={errors.city ?? errors.location_city}>
            <input className="input" id="ap-city" name="city" autoComplete="address-level2" value={d.city} onChange={(e) => { set('city', e.target.value); clear('location_city'); }}
              aria-invalid={!!(errors.city ?? errors.location_city) || undefined} aria-describedby={describedBy('ap-city', errors.city ?? errors.location_city, false)} data-testid="ap-city" /></Field>
          <Field id="ap-region" label="Province or state" optional>
            <input className="input" id="ap-region" name="region" autoComplete="address-level1" value={d.region} onChange={(e) => set('region', e.target.value)} data-testid="ap-region" /></Field>
          <Field id="ap-country" label="Country">
            <select className="select" id="ap-country" name="country" autoComplete="country" value={d.country} onChange={(e) => set('country', e.target.value)} data-testid="ap-country">
              {COUNTRIES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}</select></Field>
        </fieldset>}
        {input('profile_name', src === 'onlinejobs' ? 'Name on your OnlineJobs.ph profile, if different' : 'Name on your Indeed profile, if different', 'text', 'off', true)}
      </fieldset>
      <fieldset className="stack-lg cr-group">
        <legend className="d4">About the role</legend>
        {role.questions.map((q, n) => <QuestionField key={q.key} q={q} n={n + 1} value={d.answers[q.key]} error={errors[q.key]} onChange={(v) => answer(q.key, v)}
          onBlur={q.key === 'pay' ? checkPay : undefined} />)}
      </fieldset>
      <div className="cr-hp" aria-hidden="true"><label htmlFor="ap-website">Website</label><input id="ap-website" name="website" tabIndex={-1} autoComplete="off" /></div>
      {payNote && <PayNote kind={payNote} payText={role.pay_text} max={payMax} unit={role.pay_unit} currency={role.pay_currency}
        onAccept={() => { payAcked.current = true; if (payNote === 'no' && payYes) answer('pay', payYes); else if (payMax) answer('pay', String(payMax / 100)); setPayNote(null); }}
        onKeep={() => { payAcked.current = true; setPayNote(null); }} />}
      <Turnstile action="job_apply" />
      <button className="btn btn--primary btn--lg" type="submit" disabled={busy} data-testid="ap-submit">{busy ? 'Sending' : 'Send my application'}</button>
      <p className="small muted" aria-live="polite">{saved ? 'Saved on this device as you type. ' : ''}We use your answers only to assess your application; see our <Link className="link" href="/privacy">Privacy policy</Link>.</p>
    </form>
  );
}

function QuestionField({ q, n, value, error, onChange, onBlur }: { q: Question; n: number; value: string | string[] | undefined; error?: string; onChange: (v: string | string[]) => void; onBlur?: () => void }) {
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
        : q.type === 'date'
          ? <DateInput className="input" id={id} value={v} onChange={(e) => onChange(e.target.value)} onBlur={onBlur}
              aria-invalid={!!error || undefined} aria-describedby={describedBy(id, error, !!q.hint)} data-testid={`q-${q.key}`} />
          : <input className="input" id={id} type="text" maxLength={300} placeholder={q.placeholder} value={v} onChange={(e) => onChange(e.target.value)} onBlur={onBlur}
              aria-invalid={!!error || undefined} aria-describedby={describedBy(id, error, !!q.hint)} data-testid={`q-${q.key}`} />}
    </Field>
  );
}

// A modal note about the role's fixed pay: the pay, then accept it, keep my answer, or see the other roles.
function PayNote({ kind, payText, max, unit, currency, onAccept, onKeep }: { kind: 'over' | 'no'; payText: string; max: number | null; unit: 'HOUR' | 'MONTH' | null;
  currency: string | null; onAccept: () => void; onKeep: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { const dl = ref.current; if (dl && !dl.open) dl.showModal?.(); }, []);
  const most = max ? `${currency && currency !== 'CAD' ? `${currency} ` : ''}$${(max / 100).toLocaleString('en-CA', { maximumFractionDigits: 2 })}${unit === 'HOUR' ? ' an hour' : unit === 'MONTH' ? ' a month' : ''}` : payText;
  return (
    <dialog ref={ref} className="modal" aria-labelledby="cr-pay-h" onCancel={(e) => { e.preventDefault(); onKeep(); }} data-testid="apply-pay-note">
      <div className="modal__head"><h2 className="d4" id="cr-pay-h">This role pays {payText}</h2></div>
      <div className="modal__body stack">
        <p>{kind === 'over' ? `The pay is set for this role and we cannot go above ${most}. If that works for you, keep going.` : 'The pay is set for this role and we cannot change it. If it does not work for you, another role may suit you better.'}</p>
        <p><Link prefetch={false} className="link" href="/careers">See the other open roles</Link></p>
      </div>
      <div className="modal__foot" style={{ flexWrap: 'wrap' }}>
        <button type="button" className="btn btn--ghost" onClick={onKeep} data-testid="apply-pay-keep">Keep my answer</button>
        <button type="button" className="btn btn--primary" onClick={onAccept} data-testid="apply-pay-accept">{kind === 'over' ? `${most} works for me` : 'I accept this pay'}</button>
      </div>
    </dialog>
  );
}
