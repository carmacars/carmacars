'use client';
import Link from 'next/link';
import { useEffect, useId, useRef, useState, useTransition, type KeyboardEvent } from 'react';
import { cleanCode } from '@/features/auth/phone';
import { describedBy, Field } from '@/features/forms/Field';
import { phoneGateSave, phoneGateSendCode } from '@/server/actions/phone-gate';
import { DEALS_TEXT, formatAsTyped, GATE_TEXT, gateNumber, type GateKind, type GateRules } from './rules';

// The phone number box (migration 0280): one small dialog (a sheet on phones). The mobile number, formatted as it is
// typed, the unticked "Also text me deals" box and Continue; with the code setting on, a 6-digit code by text first.
// A native modal dialog: the page behind is inert, Tab stays inside, Escape or the close button closes it and the focus
// goes back to what was tapped.
const RESEND_SECONDS = 60;

export function PhoneGateDialog({ kind, rules, onDone, onClose }: { kind: GateKind; rules: GateRules; onDone: (phone: string) => void; onClose: () => void }) {
  const id = useId().replace(/:/g, '');
  const ref = useRef<HTMLDialogElement>(null);
  const [phone, setPhone] = useState('');
  const [deals, setDeals] = useState(false);
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
    const r = await phoneGateSave({ phone: p.phone, gate: kind, page: location.pathname, marketing: deals, code: p.code ?? null, unverified: p.unverified });
    if (!r.ok) { setErr({ field: r.fieldErrors?.code ? 'code' : r.fieldErrors?.phone ? 'phone' : undefined, message: r.message }); return; }
    onDone(r.data.phone);
  });
  const sendCode = (n: string) => start(async () => {
    const r = await phoneGateSendCode({ phone: n, gate: kind });
    if (!r.ok) { setErr({ field: r.fieldErrors?.phone ? 'phone' : undefined, message: r.message }); return; }
    // a US number before US texting is registered: no code can go, the number is enough
    if (r.data.noTexts) { const s = await phoneGateSave({ phone: r.data.phone, gate: kind, page: location.pathname, marketing: deals }); if (s.ok) onDone(s.data.phone); else setErr({ message: s.message }); return; }
    setSent(r.data); setCode(''); setStep('code'); setLeft(RESEND_SECONDS);
  });
  const submit = () => {
    setErr(null);
    if (step === 'phone') {
      const n = gateNumber(phone);
      if (!n.ok) { setErr({ field: 'phone', message: n.message }); return; }
      if (rules.verify) sendCode(n.phone); else save({ phone: n.phone });
    } else if (sent) {
      if (!cleanCode(code)) { setErr({ field: 'code', message: 'Enter the 6 digits from the text.' }); return; }
      save({ phone: sent.phone, code });
    }
  };
  const fe = (f: 'phone' | 'code') => (err?.field === f ? err.message : undefined);

  return (
    <dialog ref={ref} className="modal modal--sheet pgate" aria-labelledby={`${id}-t`} aria-describedby={`${id}-d`} onKeyDown={trap} data-testid="phone-gate">
      <div className="modal__head">
        <h2 className="d3" id={`${id}-t`}>Your mobile number</h2>
        <button type="button" className="modal__close" aria-label="Close" onClick={onClose} data-testid="phone-gate-close">×</button>
      </div>
      <form className="modal__body stack" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }}>
        <p id={`${id}-d`}>{GATE_TEXT[kind]}</p>
        {err && !err.field && <p className="alert alert--error" role="alert"><span>{err.message}</span></p>}
        {step === 'phone' && <>
          <Field id={`${id}-p`} label="Mobile number" error={fe('phone')}>
            <input className="input" id={`${id}-p`} name="phone" type="tel" inputMode="tel" autoComplete="tel-national" autoFocus placeholder="(647) 555-1234"
              value={phone} onChange={(e) => setPhone(formatAsTyped(e.target.value))} aria-invalid={!!fe('phone') || undefined}
              aria-describedby={describedBy(`${id}-p`, fe('phone'))} data-testid="phone-gate-number" />
          </Field>
          <label className="check small"><input type="checkbox" checked={deals} onChange={(e) => setDeals(e.target.checked)} data-testid="phone-gate-deals" /><span>{DEALS_TEXT}</span></label>
        </>}
        {step === 'code' && sent && <>
          <p role="status" data-testid="phone-gate-sent">We texted a 6-digit code to <strong>{sent.display}</strong>.</p>
          <Field id={`${id}-c`} label="6-digit code" error={fe('code')}>
            <input className="input input--code" id={`${id}-c`} name="code" autoFocus inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]*" maxLength={7}
              value={code} onChange={(e) => { const v = e.target.value.replace(/[^\d\s-]/g, '').slice(0, 7); setCode(v); if (cleanCode(v) && !pending) save({ phone: sent.phone, code: v }); }}
              aria-invalid={!!fe('code') || undefined} aria-describedby={describedBy(`${id}-c`, fe('code'))} data-testid="phone-gate-code" />
          </Field>
        </>}
        <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={pending} data-testid="phone-gate-continue">{pending ? 'One moment' : 'Continue'}</button>
        {step === 'code' && sent && <p className="row small" style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}>
          <button type="button" className="link" disabled={pending || left > 0} onClick={() => sendCode(sent.phone)} data-testid="phone-gate-resend">{left > 0 ? `Send a new code in ${left} s` : 'Send a new code'}</button>
          <button type="button" className="link" onClick={() => { setStep('phone'); setErr(null); }}>Use another number</button>
          {rules.allow_unverified && <button type="button" className="link" onClick={() => save({ phone: sent.phone, unverified: true })} data-testid="phone-gate-skip">Use without verifying</button>}
        </p>}
        <p className="xs muted"><Link prefetch={false} className="link" href="/privacy" target="_blank">Privacy policy</Link></p>
      </form>
    </dialog>
  );
}
