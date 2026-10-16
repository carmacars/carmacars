'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import type { ActionResult } from '@/features/forms/schemas';
import { SignatureInput, type SignatureValue } from './SignatureInput';

// One signature for a whole package of documents (migration 0049): the documents listed, the statements the documents
// themselves ask to be ticked or initialled (one tap ticks them all; each stays visible), the signature (the legal name
// on file, adopted, or drawn), and one button whose label says what signing means. The server signs each document with
// that one signature and records the package. On a phone the whole form is three taps.
export interface PackageInput {
  method: 'typed' | 'drawn'; typedName?: string; drawn?: string; initials?: string; statements: string[];
  legalAdvice?: 'obtained' | 'declined'; adviser?: string; secondsToSign: number;
}
export type PackageResult = ActionResult<{ next?: string; signed: number; message?: string }>;
export interface Statement { code: string; title?: string; text: string }

const initialsOf = (name: string) => name.split(/\s+/).filter((w) => /^[A-Za-z]/.test(w)).map((w) => w[0]!.toUpperCase()).join('').slice(0, 4);

export function PackageSignForm({ docs, signerName, fixNameHref, statements = [], statementsLegend = 'You confirm', initials = false, investment = false,
  consent, button, action, after, testId = 'package-sign-form' }: {
  docs: Array<{ key: string; title: string }>; signerName: string; fixNameHref?: string; statements?: Statement[]; statementsLegend?: string; initials?: boolean;
  investment?: boolean; consent: string; button: string; action: (input: PackageInput) => Promise<PackageResult>;
  /** runs in the browser after the server signed (the official registry forms are filled and signed here) */
  after?: (sig: SignatureValue) => Promise<string | null>; testId?: string;
}) {
  const router = useRouter();
  const opened = useRef(0);
  useEffect(() => { opened.current = Date.now(); }, []);
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [ini, setIni] = useState(initialsOf(signerName));
  const [sig, setSig] = useState<SignatureValue>(null);
  const [advice, setAdvice] = useState<'' | 'obtained' | 'declined'>('');
  const [adviser, setAdviser] = useState('');
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const all = statements.length > 0 && statements.every((s) => ticked.has(s.code));
  const toggleAll = (on: boolean) => { setTicked(on ? new Set(statements.map((s) => s.code)) : new Set()); setErrs((e) => ({ ...e, statements: '' })); };
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (statements.length && !all) fe.statements = statements.length > 1 ? `Tick the ${statements.length} statements (one tap on "All of these").` : 'Tick the statement.';
    if (initials && !/^[A-Za-z]{1,4}$/.test(ini.trim())) fe.initials = 'Your initials, letters only.';
    if (investment && !advice) fe.advice = 'Say whether you got independent legal advice.';
    if (!sig) fe.signature = 'Draw your signature in the box, or use your name.';
    setErrs(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>(`[data-testid="${testId}"] [aria-invalid="true"]`)?.focus()); return; }
    setBusy(true);
    try {
      const r = await action({ method: sig!.method, typedName: sig!.method === 'typed' ? sig!.typedName : undefined, drawn: sig!.method === 'drawn' ? sig!.png : undefined,
        initials: initials ? ini.trim().toUpperCase() : undefined, statements: [...ticked], legalAdvice: investment ? (advice as 'obtained' | 'declined') : undefined,
        adviser: investment && advice === 'obtained' ? adviser.trim() : undefined, secondsToSign: Math.round((Date.now() - opened.current) / 1000) });
      if (!r.ok) { setErrs({ ...(r.fieldErrors ?? {}), form: r.fieldErrors ? '' : r.message }); return; }
      const extra = after ? await after(sig) : null;
      setDone([r.data.message ?? 'Signed. Your signed copies are in your documents.', extra].filter(Boolean).join(' '));
      if (r.data.next) router.push(r.data.next); else router.refresh();
    } catch (x) { setErrs({ form: x instanceof Error ? x.message : 'Something went wrong. Try again.' }); } finally { setBusy(false); }
  };
  if (done) return <p className="alert alert--ok" role="status" data-testid="package-signed"><span>{done}</span></p>;
  const id = testId;
  return (
    <form className="stack-lg" noValidate onSubmit={submit} aria-label={button} data-testid={testId}>
      {docs.length > 1 && <p className="small" data-testid="package-docs">One signature for these {docs.length} documents: {docs.map((d) => d.title).join(', ')}.</p>}
      {statements.length > 0 && (
        <fieldset className="pt-consents" aria-describedby={`${id}-st-err`} aria-invalid={!!errs.statements || undefined} tabIndex={-1}>
          <legend>{statementsLegend}</legend>
          {statements.length > 1 && (
            <label className="check pk-all"><input type="checkbox" checked={all} onChange={(e) => toggleAll(e.target.checked)} data-testid="package-tick-all" /><span><b>All of these</b> (one tap ticks the {statements.length} statements below)</span></label>
          )}
          <div className={statements.length > 1 ? 'pk-statements' : undefined}>
            {statements.map((s) => (
              <label key={s.code} className="check">
                <input type="checkbox" name="statement" value={s.code} checked={ticked.has(s.code)} onChange={(e) => { const n = new Set(ticked); if (e.target.checked) n.add(s.code); else n.delete(s.code); setTicked(n); setErrs((x) => ({ ...x, statements: '' })); }} />
                <span>{s.title ? <b>{s.title}. </b> : null}{s.text}</span>
              </label>
            ))}
          </div>
          <p className="error" role="alert" id={`${id}-st-err`}>{errs.statements ?? ''}</p>
          {initials && (
            <div className={`field${errs.initials ? ' has-error' : ''}`}>
              <label className="label" htmlFor={`${id}-ini`}>Your initials for these statements</label>
              <input className="input" id={`${id}-ini`} value={ini} onChange={(e) => { setIni(e.target.value.toUpperCase()); setErrs((x) => ({ ...x, initials: '' })); }} maxLength={4} autoComplete="off"
                aria-invalid={!!errs.initials || undefined} aria-describedby={`${id}-ini-err`} style={{ maxWidth: '8rem' }} data-testid="package-initials" />
              <p className="error" role="alert" id={`${id}-ini-err`}>{errs.initials ?? ''}</p>
            </div>
          )}
        </fieldset>
      )}
      {investment && (
        <fieldset className="pt-consents" aria-describedby={`${id}-adv-err`} aria-invalid={!!errs.advice || undefined} tabIndex={-1}>
          <legend>Independent legal advice (Schedule C)</legend>
          <label className="check"><input type="radio" name="advice" checked={advice === 'obtained'} onChange={() => setAdvice('obtained')} /><span>I got independent legal advice before signing.</span></label>
          <label className="check"><input type="radio" name="advice" checked={advice === 'declined'} onChange={() => setAdvice('declined')} /><span>I was told I could get independent legal advice and chose not to.</span></label>
          <p className="error" role="alert" id={`${id}-adv-err`}>{errs.advice ?? ''}</p>
          {advice === 'obtained' && <div className="field"><label className="label" htmlFor={`${id}-adviser`}>Your lawyer&apos;s name (optional)</label><input className="input" id={`${id}-adviser`} value={adviser} onChange={(e) => setAdviser(e.target.value)} /></div>}
        </fieldset>
      )}
      <div className={`field${errs.signature ? ' has-error' : ''}`}>
        <SignatureInput id={`${id}-sig`} name={signerName} fixHref={fixNameHref} onChange={(v) => { setSig(v); if (v) setErrs((x) => ({ ...x, signature: '' })); }} invalid={!!errs.signature} describedBy={`${id}-sig-err`} />
        <p className="error" role="alert" id={`${id}-sig-err`}>{errs.signature ?? ''}</p>
      </div>
      {errs.form && <p className="alert alert--error" role="alert" data-testid="package-error"><span>{errs.form}</span></p>}
      <div className="stack">
        <p className="small muted" data-testid="package-consent">{consent}</p>
        <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={busy} data-testid="package-sign">{busy ? 'Signing' : button}</button>
      </div>
    </form>
  );
}
