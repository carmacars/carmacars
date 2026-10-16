'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { SignaturePad } from '@/features/portal/SignaturePad';
import { useAct } from '@/features/portal/useAct';
import { signRequest } from '@/server/actions/manual-records';

// Signing one document in a portal (migration 0044): Forms A and B (owners), investment agreements (investors) and staff
// agreements (VA and Field). The same pad as the rental and owner agreements: draw, or type the full legal name.
export function PortalSignForm({ id, sha, signerName, statement, investment = false, done }: { id: string; sha: string; signerName: string; statement: string; investment?: boolean; done: string }) {
  const router = useRouter();
  const [mode, setMode] = useState<'draw' | 'type'>('draw');
  const [png, setPng] = useState<string | null>(null);
  const [typed, setTyped] = useState('');
  const [agree, setAgree] = useState(false);
  const [advice, setAdvice] = useState<'' | 'obtained' | 'declined'>('');
  const [adviser, setAdviser] = useState('');
  const [initials, setInitials] = useState('');
  const [local, setLocal] = useState<Record<string, string>>({});
  const a = useAct<{ status: string }>();
  const err = (k: string) => local[k] || a.err(k);
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (!agree) fe.agree = 'Tick the box to sign electronically.';
    if (investment && !advice) fe.advice = 'Say whether you got independent legal advice.';
    if (investment && !/^[A-Za-z]{1,4}$/.test(initials.trim())) fe.initials = 'Type your initials (letters only).';
    if (mode === 'draw' && !png) fe.signature = 'Please sign your name in the box.';
    if (mode === 'type' && typed.replace(/\s+/g, '').toLowerCase() !== signerName.replace(/\s+/g, '').toLowerCase()) fe.signature = `Type your full legal name exactly: ${signerName}.`;
    setLocal(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus()); return; }
    a.run(() => signRequest({ id, sha, consent: statement, drawn: mode === 'draw' ? png ?? undefined : undefined, typedName: mode === 'type' ? typed : undefined,
      legalAdvice: investment ? (advice as 'obtained' | 'declined') : undefined, adviser: investment ? adviser : undefined, initials: investment ? initials.trim() : undefined }), (r) => { if (r.ok) router.refresh(); });
  };
  if (a.res?.ok) return <p className="alert alert--ok" role="status" data-testid="portal-signed"><span>{done}</span></p>;
  return (
    <form className="stack-lg" noValidate onSubmit={submit} aria-label="Sign the document" data-testid="portal-sign-form">
      {investment && (
        <>
          <fieldset className="pt-consents" aria-describedby="ps-adv-err" aria-invalid={!!err('advice') || undefined} tabIndex={-1}>
            <legend>Independent legal advice</legend>
            <label className="check"><input type="radio" name="advice" checked={advice === 'obtained'} onChange={() => setAdvice('obtained')} /><span>I got independent legal advice before signing.</span></label>
            <label className="check"><input type="radio" name="advice" checked={advice === 'declined'} onChange={() => setAdvice('declined')} /><span>I was told I could get independent legal advice and chose not to.</span></label>
            <p className="error" role="alert" id="ps-adv-err">{err('advice') ?? ''}</p>
          </fieldset>
          {advice === 'obtained' && <div className="field"><label className="label" htmlFor="ps-adviser">Your lawyer&apos;s name (optional)</label><input className="input" id="ps-adviser" value={adviser} onChange={(e) => setAdviser(e.target.value)} /></div>}
          <div className={`field${err('initials') ? ' has-error' : ''}`}>
            <label className="label" htmlFor="ps-initials">Your initials, for the risk acknowledgment (Schedule C)</label>
            <input className="input" id="ps-initials" value={initials} onChange={(e) => setInitials(e.target.value.toUpperCase())} maxLength={4} autoComplete="off" aria-invalid={!!err('initials') || undefined} aria-describedby="ps-initials-err" style={{ maxWidth: '8rem' }} />
            <p className="error" role="alert" id="ps-initials-err">{err('initials') ?? ''}</p>
          </div>
        </>
      )}
      <div className={`field${err('signature') ? ' has-error' : ''}`}>
        <div className="sigpad__tools">
          <span className="label" id="ps-sig-label">{mode === 'draw' ? 'Draw your signature' : 'Type your full legal name'}</span>
          <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setMode(mode === 'draw' ? 'type' : 'draw'); setLocal({}); }}>{mode === 'draw' ? 'Type my name instead' : 'Draw instead'}</button>
        </div>
        {mode === 'draw'
          ? <SignaturePad id="ps-sig" onChange={(p) => { setPng(p); if (p) setLocal((l) => ({ ...l, signature: '' })); }} invalid={!!err('signature')} describedBy="ps-sig-err" />
          : <input className="input sigpad__typed" id="ps-sig" aria-labelledby="ps-sig-label" value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="name" placeholder={signerName} aria-invalid={!!err('signature') || undefined} aria-describedby="ps-sig-hint ps-sig-err" />}
        {mode === 'type' && <p className="hint" id="ps-sig-hint">It must match: {signerName}.</p>}
        <p className="error" role="alert" id="ps-sig-err">{err('signature') ?? ''}</p>
      </div>
      <label className={`check${err('agree') ? ' has-error' : ''}`}>
        <input type="checkbox" checked={agree} onChange={(e) => { setAgree(e.target.checked); setLocal((l) => ({ ...l, agree: '' })); }} aria-invalid={!!err('agree') || undefined} aria-describedby="ps-agree-err" />
        <span>{statement}</span>
      </label>
      <p className="error" role="alert" id="ps-agree-err">{err('agree') ?? ''}</p>
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={a.pending}>{a.pending ? 'Signing' : 'Sign'}</button>
    </form>
  );
}
