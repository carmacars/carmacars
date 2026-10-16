'use client';
import { useState } from 'react';
import { signAgreement, signAsDriver } from '@/server/actions/portal';
import type { Consent } from '@/features/agreement/model';
import { SignatureInput, type SignatureValue } from '@/features/signing/SignatureInput';
import { useAct } from './useAct';

// The rental agreement's signature (migration 0049, simpler): the four statements of Part 6 stay on screen word for
// word, and one tap on "All four" ticks them; the signature is the legal name on file (adopted) or drawn; one button.
export function SignForm({ number, token, sha, consents, legalName, button, onDone, fixNameHref }: { number?: string; token?: string; sha: string; consents: Consent[]; legalName: string; button: string; onDone?: () => void; fixNameHref?: string }) {
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [sig, setSig] = useState<SignatureValue>(null);
  const [local, setLocal] = useState<Record<string, string>>({});
  const a = useAct();
  const err = (k: string) => local[k] ?? a.err(k);
  const all = consents.every((c) => ticked.has(c.code));
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (!all) fe.consents = consents.length > 1 ? `Tick the ${consents.length === 4 ? 'four' : consents.length} statements (one tap on "All ${consents.length === 4 ? 'four' : consents.length}").` : 'Tick the statement.';
    if (!sig) fe.signature = 'Draw your signature in the box, or use your name.';
    setLocal(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus()); return; }
    const input = { consents: [...ticked], sha, drawn: sig!.method === 'drawn' ? sig!.png : undefined, typedName: sig!.method === 'typed' ? sig!.typedName : undefined };
    a.run(() => (token ? signAsDriver(token, input) : signAgreement(number!, input)), (r) => { if (r.ok) onDone?.(); });
  };
  return (
    <form className="stack-lg" noValidate onSubmit={submit} aria-label="Sign the rental agreement">
      <fieldset className="pt-consents" aria-describedby="pt-consents-err" aria-invalid={!!err('consents') || undefined} tabIndex={-1}>
        <legend>Before you sign</legend>
        {consents.length > 1 && (
          <label className="check pk-all"><input type="checkbox" checked={all} onChange={(e) => { setTicked(e.target.checked ? new Set(consents.map((c) => c.code)) : new Set()); setLocal((l) => ({ ...l, consents: '' })); }} data-testid="consents-all" />
            <span><b>All {consents.length === 4 ? 'four' : consents.length}</b>: I agree to each statement below</span></label>
        )}
        <div className="pk-statements">
          {consents.map((c) => (
            <label key={c.code} className="check">
              <input type="checkbox" name="consent" value={c.code} checked={ticked.has(c.code)} onChange={(e) => { const n = new Set(ticked); if (e.target.checked) n.add(c.code); else n.delete(c.code); setTicked(n); setLocal((l) => ({ ...l, consents: '' })); }} />
              <span><b>{c.n}. {c.title}.</b> {c.text}</span>
            </label>
          ))}
        </div>
        <p className="error" role="alert" id="pt-consents-err">{err('consents') ?? ''}</p>
      </fieldset>
      <div className={`field${err('signature') ? ' has-error' : ''}`}>
        <SignatureInput id="pt-sig" name={legalName} fixHref={fixNameHref} onChange={(v) => { setSig(v); if (v) setLocal((l) => ({ ...l, signature: '' })); }} invalid={!!err('signature')} describedBy="pt-sig-err" />
        <p className="error" role="alert" id="pt-sig-err">{err('signature') ?? ''}</p>
      </div>
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && token ? <p className="alert alert--ok" role="status"><span className="alert__title">Accepted</span><span>Thank you. You have accepted the rental agreement.</span></p>
        : <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={a.pending} data-testid="rental-sign">{a.pending ? 'Signing' : button}</button>}
    </form>
  );
}
