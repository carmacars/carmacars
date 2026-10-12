'use client';
import { useState } from 'react';
import { SignaturePad } from '@/features/portal/SignaturePad';
import { useAct } from '@/features/portal/useAct';
import { signOwnerAgreements } from '@/server/actions/owner';
import type { PacketKey } from '@/features/owner-agreement/model';

// The owner's one signature for the whole packet: three initialled confirmations (each its own tick),
// the initials, then a drawn or typed signature (the same pad as the rental agreement).
export function OwnerSignForm({ docs, confirmations, signerName }: { docs: Array<{ key: PacketKey; sha: string; title: string }>; confirmations: Array<{ code: string; text: string }>; signerName: string }) {
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [initials, setInitials] = useState('');
  const [mode, setMode] = useState<'draw' | 'type'>('draw');
  const [png, setPng] = useState<string | null>(null);
  const [typed, setTyped] = useState('');
  const [local, setLocal] = useState<Record<string, string>>({});
  const a = useAct();
  const err = (k: string) => local[k] || a.err(k);
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (confirmations.length) {
      if (!confirmations.every((c) => ticked.has(c.code))) fe.confirmations = 'Tick each of the three confirmations.';
      if (!/^[A-Za-z]{1,4}$/.test(initials.trim())) fe.initials = 'Type your initials (letters only).';
    }
    if (mode === 'draw' && !png) fe.signature = 'Please sign your name in the box.';
    if (mode === 'type' && typed.replace(/\s+/g, '').toLowerCase() !== signerName.replace(/\s+/g, '').toLowerCase()) fe.signature = `Type your full legal name exactly: ${signerName}.`;
    setLocal(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus()); return; }
    a.run(() => signOwnerAgreements({ docs: docs.map((d) => ({ key: d.key, sha: d.sha })), initials: initials.trim(), confirmations: [...ticked], drawn: mode === 'draw' ? png ?? undefined : undefined, typedName: mode === 'type' ? typed : undefined }));
  };
  return (
    <form className="stack-lg" noValidate onSubmit={submit} aria-label="Sign the agreements">
      <ul className="small" style={{ margin: 0, paddingLeft: '1.2rem' }}>{docs.map((d) => <li key={d.key}>{d.title}</li>)}</ul>
      {confirmations.length > 0 && (
        <fieldset className="pt-consents" aria-describedby="ow-conf-err" aria-invalid={!!err('confirmations') || undefined} tabIndex={-1}>
          <legend>The Owner confirms</legend>
          {confirmations.map((c) => (
            <label key={c.code} className="check">
              <input type="checkbox" checked={ticked.has(c.code)} onChange={(e) => { const n = new Set(ticked); if (e.target.checked) n.add(c.code); else n.delete(c.code); setTicked(n); setLocal((l) => ({ ...l, confirmations: '' })); }} />
              <span>{c.text}</span>
            </label>
          ))}
          <p className="error" role="alert" id="ow-conf-err">{err('confirmations') ?? ''}</p>
          <div className={`field${err('initials') ? ' has-error' : ''}`}>
            <label className="label" htmlFor="ow-initials">Your initials, for the three confirmations</label>
            <input className="input" id="ow-initials" value={initials} onChange={(e) => { setInitials(e.target.value.toUpperCase()); setLocal((l) => ({ ...l, initials: '' })); }} maxLength={4} autoComplete="off" aria-invalid={!!err('initials') || undefined} aria-describedby="ow-initials-err" style={{ maxWidth: '8rem' }} />
            <p className="error" role="alert" id="ow-initials-err">{err('initials') ?? ''}</p>
          </div>
        </fieldset>
      )}
      <div className={`field${err('signature') ? ' has-error' : ''}`}>
        <div className="sigpad__tools">
          <span className="label" id="ow-sig-label">{mode === 'draw' ? 'Draw your signature' : 'Type your full legal name'}</span>
          <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setMode(mode === 'draw' ? 'type' : 'draw'); setLocal({}); }}>{mode === 'draw' ? 'Type my name instead' : 'Draw instead'}</button>
        </div>
        {mode === 'draw'
          ? <SignaturePad id="ow-sig" onChange={(p) => { setPng(p); if (p) setLocal((l) => ({ ...l, signature: '' })); }} invalid={!!err('signature')} describedBy="ow-sig-err" />
          : <input className="input sigpad__typed" id="ow-sig" aria-labelledby="ow-sig-label" value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="name" placeholder={signerName} aria-invalid={!!err('signature') || undefined} aria-describedby="ow-sig-hint ow-sig-err" />}
        {mode === 'type' && <p className="hint" id="ow-sig-hint">It must match: {signerName}.</p>}
        <p className="error" role="alert" id="ow-sig-err">{err('signature') ?? ''}</p>
      </div>
      <p className="small muted">By signing you agree to sign these documents electronically. CarmaCars countersigns at the same moment. You get the signed copies in Documents.</p>
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={a.pending}>{a.pending ? 'Signing' : `Sign ${docs.length > 1 ? `all ${docs.length}` : ''}`.trim()}</button>
    </form>
  );
}
