'use client';
import Link from 'next/link';
import { useEffect, useId, useRef, useState, useTransition, type KeyboardEvent } from 'react';
import { cleanCode } from '@/features/auth/phone';
import { phoneGateSave, phoneGateSendCode } from '@/server/actions/phone-gate';
import { formatAsTyped, GATE_WHY, gateNumber, type GateKind, type GateRules } from './rules';

// The phone number box (migration 0280; 2026-11-06 the owner's simpler box): one small dialog (a sheet on phones) with
// "What's your number?", one line on what it opens, one big number field formatted as it is typed and sent by itself at
// ten digits, and the close button. With the code setting on, a 6-digit code by text first, also sent by itself.
// A native modal dialog: the page behind is inert, Tab stays inside, Escape or the close button closes it and the focus
// goes back to what was tapped.
const RESEND_SECONDS = 60;

export function PhoneGateDialog({ kind, rules, onDone, onClose }: { kind: GateKind; rules: GateRules; onDone: (phone: string) => void; onClose: () => void }) {
  const id = useId().replace(/:/g, '');
  const ref = useRef<HTMLDialogElement>(null);
  const [phone, setPhone] = useState('');
  const [step, setStep] = useState<'phone' | 'code'>('phone');
  const [sent, setSent] = useState<{ phone: string; display: string } | null>(null);
  const [code, setCode] = useState('');
  const [err, setErr] = useState<{ field?: 'phone' | 'code'; message: string } | null>(null);
  const [left, setLeft] = useState(0);
  const [pending, start] = useTransition();
  const closeRef = useRef(onClose);
  useEffect(() => { closeRef.current = onClose; });

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (!d.open) d.showModal();
    // showModal moves the focus to the dialog's first control (React's autoFocus ran before it): the number field it is
    d.querySelector<HTMLInputElement>('input[name="phone"], input[name="code"]')?.focus();
    const cancel = (e: Event) => { e.preventDefault(); closeRef.current(); };
    d.addEventListener('cancel', cancel);
    return () => { d.removeEventListener('cancel', cancel); if (d.open) d.close(); };
  }, []);
  useEffect(() => {
    if (left <= 0) return;
    const t = setTimeout(() => setLeft((n) => n - 1), 1000);
    return () => clearTimeout(t);
  }, [left]);

  // Tab and Shift+Tab stay inside the box
  const trap = (e: KeyboardEvent<HTMLDialogElement>) => {
    if (e.key !== 'Tab' || !ref.current) return;
    const f = [...ref.current.querySelectorAll<HTMLElement>('button:not([disabled]), input:not([disabled]), a[href]')].filter((x) => x.offsetParent !== null);
    if (!f.length) return;
    const first = f[0]!, last = f[f.length - 1]!;
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  };

  const save = (p: { phone: string; code?: string; unverified?: boolean }) => start(async () => {
    const r = await phoneGateSave({ phone: p.phone, gate: kind, page: location.pathname, marketing: false, code: p.code ?? null, unverified: p.unverified });
    if (!r.ok) { tried.current = ''; setErr({ field: r.fieldErrors?.code ? 'code' : r.fieldErrors?.phone ? 'phone' : undefined, message: r.message }); return; }
    done(r.data.phone);
  });
  const sendCode = (n: string) => start(async () => {
    const r = await phoneGateSendCode({ phone: n, gate: kind });
    if (!r.ok) { tried.current = ''; setErr({ field: r.fieldErrors?.phone ? 'phone' : undefined, message: r.message }); return; }
    // a US number before US texting is registered: no code can go, the number is enough
    if (r.data.noTexts) { const s = await phoneGateSave({ phone: r.data.phone, gate: kind, page: location.pathname, marketing: false }); if (s.ok) done(s.data.phone); else setErr({ message: s.message }); return; }
    setSent(r.data); setCode(''); setStep('code'); setLeft(RESEND_SECONDS);
  });
  // 2026-11-06 (the owner: "literally just the field to input the number and the x"): no Continue button. The number is
  // sent by itself once ten digits make a valid Canadian or US mobile number; a short spinner, a quiet "Thanks", then
  // the photos or the calendar. The code step (when the code setting is on) already sends itself at six digits.
  const [state, setState] = useState<'idle' | 'busy' | 'ok'>('idle');
  const tried = useRef('');
  const done = (n: string) => { setState('ok'); setTimeout(() => onDone(n), 450); };
  const typed = (v: string) => {
    const f = formatAsTyped(v);
    setPhone(f); setErr(null);
    if (f.replace(/\D/g, '').length < 10) { tried.current = ''; return; }
    const n = gateNumber(f);
    if (!n.ok) { setErr({ field: 'phone', message: n.message }); return; }
    if (tried.current === n.phone || pending) return;
    tried.current = n.phone;
    if (rules.verify) sendCode(n.phone); else save({ phone: n.phone });
  };
  const fe = (f: 'phone' | 'code') => (err?.field === f ? err.message : undefined);
  const busy = pending || state === 'busy';

  return (
    <dialog ref={ref} className="modal modal--sheet pgate" aria-labelledby={`${id}-t`} aria-describedby={`${id}-d`} onKeyDown={trap} data-testid="phone-gate">
      <button type="button" className="modal__close pgate__x" aria-label="Close" onClick={onClose} data-testid="phone-gate-close">×</button>
      <form className="pgate__body" noValidate onSubmit={(e) => { e.preventDefault(); if (step === 'phone') { tried.current = ''; typed(phone); } else if (sent && cleanCode(code)) save({ phone: sent.phone, code }); }}>
        <h2 className="pgate__title" id={`${id}-t`}>{step === 'code' ? 'Check your texts\u00a0📱' : 'What’s your number?\u00a0😉'}</h2>
        <p className="pgate__why" id={`${id}-d`}>{step === 'code' && sent ? <>We texted a code to <strong>{sent.display}</strong>.</> : GATE_WHY[kind]}</p>
        {err && !err.field && <p className="pgate__err" role="alert">{err.message}</p>}
        {step === 'phone' && <div className={`pgate__field${state === 'ok' ? ' is-ok' : ''}`}>
          <label className="vh" htmlFor={`${id}-p`}>Mobile number</label>
          <input className="pgate__input" id={`${id}-p`} name="phone" type="tel" inputMode="tel" autoComplete="tel-national" autoFocus placeholder="(647) 555-1234"
            value={phone} onChange={(e) => typed(e.target.value)} aria-invalid={!!fe('phone') || undefined} readOnly={state === 'ok'}
            aria-describedby={[`${id}-d`, fe('phone') ? `${id}-p-err` : ''].filter(Boolean).join(' ')} data-testid="phone-gate-number" />
          <span className="pgate__state" aria-hidden="true">{busy && state !== 'ok' ? <i className="pgate__spin" /> : state === 'ok' ? 'Thanks' : null}</span>
        </div>}
        {step === 'code' && sent && <div className="pgate__field">
          <label className="vh" htmlFor={`${id}-c`}>6-digit code</label>
          <input className="pgate__input pgate__input--code" id={`${id}-c`} name="code" autoFocus inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]*" maxLength={7} placeholder="123456"
            value={code} readOnly={state === 'ok'} onChange={(e) => { const v = e.target.value.replace(/[^\d\s-]/g, '').slice(0, 7); setCode(v); setErr(null); if (cleanCode(v) && !pending) save({ phone: sent.phone, code: v }); }}
            aria-invalid={!!fe('code') || undefined} aria-describedby={fe('code') ? `${id}-c-err` : undefined} data-testid="phone-gate-code" />
          <span className="pgate__state" aria-hidden="true">{busy && state !== 'ok' ? <i className="pgate__spin" /> : state === 'ok' ? 'Thanks' : null}</span>
        </div>}
        <p className="pgate__err" id={`${id}-${step === 'code' ? 'c' : 'p'}-err`} aria-live="polite" data-testid="phone-gate-error">{fe(step)}</p>
        <p className="vh" role="status" aria-live="polite">{busy ? 'Checking the number' : state === 'ok' ? 'Thanks, done' : ''}</p>
        {step === 'code' && sent && <p className="pgate__links">
          <button type="button" className="link" disabled={pending || left > 0} onClick={() => sendCode(sent.phone)} data-testid="phone-gate-resend">{left > 0 ? `New code in ${left} s` : 'Send a new code'}</button>
          <button type="button" className="link" onClick={() => { setStep('phone'); setErr(null); tried.current = ''; setState('idle'); }}>Another number</button>
          {rules.allow_unverified && <button type="button" className="link" onClick={() => save({ phone: sent.phone, unverified: true })} data-testid="phone-gate-skip">Skip the code</button>}
        </p>}
        <p className="pgate__fine"><Link prefetch={false} className="link" href="/privacy" target="_blank">Privacy policy</Link></p>
        <button type="submit" hidden tabIndex={-1} aria-hidden="true" />
      </form>
    </dialog>
  );
}
