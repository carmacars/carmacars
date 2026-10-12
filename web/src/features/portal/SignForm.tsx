'use client';
import { useState } from 'react';
import { signAgreement, signAsDriver } from '@/server/actions/portal';
import type { Consent } from '@/features/agreement/model';
import { SignaturePad } from './SignaturePad';
import { useAct } from './useAct';

// Read, tick each statement (word for word, unticked), sign by drawing or by typing the legal name.
export function SignForm({ number, token, sha, consents, legalName, button, onDone }: { number?: string; token?: string; sha: string; consents: Consent[]; legalName: string; button: string; onDone?: () => void }) {
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<'draw' | 'type'>('draw');
  const [png, setPng] = useState<string | null>(null);
  const [typed, setTyped] = useState('');
  const [local, setLocal] = useState<Record<string, string>>({});
  const a = useAct();
  const err = (k: string) => local[k] ?? a.err(k);
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (!consents.every((c) => ticked.has(c.code))) fe.consents = `Tick ${consents.length === 4 ? 'all four' : 'each'} statement${consents.length > 1 ? 's' : ''} to sign.`;
    if (mode === 'draw' && !png) fe.signature = 'Please sign your name in the box.';
    if (mode === 'type' && typed.replace(/\s+/g, '').toLowerCase() !== legalName.replace(/\s+/g, '').toLowerCase()) fe.signature = `Type your full legal name exactly: ${legalName}.`;
    setLocal(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus()); return; }
    const input = { consents: [...ticked], sha, drawn: mode === 'draw' ? png ?? undefined : undefined, typedName: mode === 'type' ? typed : undefined };
    a.run(() => (token ? signAsDriver(token, input) : signAgreement(number!, input)), (r) => { if (r.ok) onDone?.(); });
  };
  return (
    <form className="stack-lg" noValidate onSubmit={submit} aria-label="Sign the rental agreement">
      <fieldset className="pt-consents" aria-describedby="pt-consents-err" aria-invalid={!!err('consents') || undefined} tabIndex={-1}>
        <legend>Before you sign, tick each statement</legend>
        {consents.map((c) => (
          <label key={c.code} className="check">
            <input type="checkbox" name="consent" value={c.code} checked={ticked.has(c.code)} onChange={(e) => { const n = new Set(ticked); if (e.target.checked) n.add(c.code); else n.delete(c.code); setTicked(n); setLocal((l) => ({ ...l, consents: '' })); }} />
            <span><b>{c.n}. {c.title}.</b> {c.text}</span>
          </label>
        ))}
        <p className="error" role="alert" id="pt-consents-err">{err('consents') ?? ''}</p>
      </fieldset>
      <div className={`field${err('signature') ? ' has-error' : ''}`}>
        <div className="sigpad__tools">
          <span className="label" id="pt-sig-label">{mode === 'draw' ? 'Draw your signature' : 'Type your full legal name'}</span>
          <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setMode(mode === 'draw' ? 'type' : 'draw'); setLocal({}); }}>{mode === 'draw' ? 'Type my name instead' : 'Draw instead'}</button>
        </div>
        {mode === 'draw'
          ? <SignaturePad id="pt-sig" onChange={(p) => { setPng(p); if (p) setLocal((l) => ({ ...l, signature: '' })); }} invalid={!!err('signature')} describedBy="pt-sig-err" />
          : <input className="input sigpad__typed" id="pt-sig" aria-labelledby="pt-sig-label" value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="name" placeholder={legalName} aria-invalid={!!err('signature') || undefined} aria-describedby="pt-sig-hint pt-sig-err" />}
        {mode === 'type' && <p className="hint" id="pt-sig-hint">It must match your legal name: {legalName}.</p>}
        <p className="error" role="alert" id="pt-sig-err">{err('signature') ?? ''}</p>
      </div>
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && token ? <p className="alert alert--ok" role="status"><span className="alert__title">Accepted</span><span>Thank you. You have accepted the rental agreement.</span></p>
        : <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={a.pending}>{a.pending ? 'Signing' : button}</button>}
    </form>
  );
}
