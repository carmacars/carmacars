'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import type { ActionResult } from '@/features/forms/schemas';
import { EsignFlow } from './EsignFlow';
import { DOC_TERMS, type Term } from './terms';
import type { EsignContext, EsignReady } from './types';

// One signature for a whole package of documents (migration 0049), given the way every signature on the site is given
// since 0181 (EsignFlow, the steps of 0154): a code to the signer's phone or email, the documents read, the key terms the
// documents ask to initial, the consents, the drawn signature. Then one button whose label says what signing means. The
// server signs each document with that one signature (the database checks it against the session) and records the package.
export interface PackageInput {
  method: 'typed' | 'drawn'; typedName?: string; drawn?: string; initials?: string; statements: string[];
  legalAdvice?: 'obtained' | 'declined'; adviser?: string; secondsToSign: number;
  /** the signing session, complete (identity, reading, initials, consents, signature) */
  esign?: EsignReady;
}
export type PackageResult = ActionResult<{ next?: string; signed: number; message?: string }>;
export interface Statement { code: string; title?: string; text: string }

export const initialsOf = (name: string) => name.split(/\s+/).filter((w) => /^[A-Za-z]/.test(w)).map((w) => w[0]!.toUpperCase()).join('').slice(0, 4) || 'X';

export function PackageSignForm({ docs, signerName, statements = [], investment = false, consent, button, action, esign, terms = DOC_TERMS, testId = 'package-sign-form' }: {
  docs: Array<{ key: string; title: string }>; signerName: string;
  /** what the documents ask to confirm: initialled as key terms in the signing steps */
  statements?: Statement[];
  investment?: boolean; consent: string; button: string; action: (input: PackageInput) => Promise<PackageResult>;
  esign: EsignContext; terms?: Term[]; testId?: string;
}) {
  const router = useRouter();
  const opened = useRef(0);
  useEffect(() => { opened.current = Date.now(); }, []);
  const [ready, setReady] = useState<EsignReady | null>(null);
  const [advice, setAdvice] = useState<'' | 'obtained' | 'declined'>('');
  const [adviser, setAdviser] = useState('');
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (investment && !advice) fe.advice = 'Say whether you got independent legal advice.';
    if (!ready) fe.signature = 'Finish the signing steps above: the code, the reading, the initials, the consents and your signature.';
    setErrs(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>(`[data-testid="${testId}"] [aria-invalid="true"]`)?.focus()); return; }
    setBusy(true);
    try {
      const r = await action({ method: ready!.method, typedName: ready!.method === 'typed' ? ready!.typedName : undefined, drawn: undefined,
        initials: initialsOf(signerName), statements: statements.map((s) => s.code), legalAdvice: investment ? (advice as 'obtained' | 'declined') : undefined,
        adviser: investment && advice === 'obtained' ? adviser.trim() : undefined, secondsToSign: Math.round((Date.now() - opened.current) / 1000), esign: ready! });
      if (!r.ok) { setErrs({ ...(r.fieldErrors ?? {}), form: r.fieldErrors ? '' : r.message }); return; }
      setDone(r.data.message ?? 'Signed. Your signed copies are in your documents.');
      if (r.data.next) router.push(r.data.next); else router.refresh();
    } catch (x) { setErrs({ form: x instanceof Error ? x.message : 'Something went wrong. Try again.' }); } finally { setBusy(false); }
  };
  if (done) return <p className="alert alert--ok" role="status" data-testid="package-signed"><span>{done}</span></p>;
  const id = testId;
  // a statement that is not a key term to initial (the co-owner's "I have read these documents and I sign them") is shown
  const plain = statements.filter((s) => !terms.some((t) => t.code === s.code));
  return (
    <form className="stack-lg" noValidate onSubmit={submit} aria-label={button} data-testid={testId}>
      {docs.length > 1 && <p className="small" data-testid="package-docs">One signature for these {docs.length} documents: {docs.map((d) => d.title).join(', ')}.</p>}
      {plain.map((s) => <p key={s.code} className="small" data-testid="package-statement">{s.title ? <b>{s.title}. </b> : null}{s.text}</p>)}
      {investment && (
        <fieldset className="pt-consents" aria-describedby={`${id}-adv-err`} aria-invalid={!!errs.advice || undefined} tabIndex={-1}>
          <legend>Independent legal advice (Schedule C)</legend>
          <label className="check"><input type="radio" name="advice" checked={advice === 'obtained'} onChange={() => setAdvice('obtained')} data-testid="package-advice-obtained" /><span>I got independent legal advice before signing.</span></label>
          <label className="check"><input type="radio" name="advice" checked={advice === 'declined'} onChange={() => setAdvice('declined')} data-testid="package-advice-declined" /><span>I was told I could get independent legal advice and chose not to.</span></label>
          <p className="error" role="alert" id={`${id}-adv-err`}>{errs.advice ?? ''}</p>
          {advice === 'obtained' && <div className="field"><label className="label" htmlFor={`${id}-adviser`}>Your lawyer&apos;s name (optional)</label><input className="input" id={`${id}-adviser`} value={adviser} onChange={(e) => setAdviser(e.target.value)} /></div>}
        </fieldset>
      )}
      <div className={`field${errs.signature ? ' has-error' : ''}`} aria-invalid={!!errs.signature || undefined} tabIndex={-1} aria-describedby={`${id}-sig-err`}>
        <EsignFlow key={esign.kind === 'documents' ? esign.docs.map((d) => d.sha).join(':') : esign.kind} ctx={esign} terms={terms} docsLabel={docs.length > 1 ? `these ${docs.length} documents` : 'the document'} onReady={(v) => { setReady(v); if (v) setErrs((x) => ({ ...x, signature: '' })); }} />
        <p className="error" role="alert" id={`${id}-sig-err`}>{errs.signature ?? ''}</p>
      </div>
      {errs.form && <p className="alert alert--error" role="alert" data-testid="package-error"><span>{errs.form}</span></p>}
      <div className="stack">
        <p className="small muted" data-testid="package-consent">{consent}</p>
        <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={busy || !ready} data-testid="package-sign">{busy ? 'Signing' : button}</button>
      </div>
    </form>
  );
}
