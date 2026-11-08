'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { EsignFlow } from '@/features/signing/EsignFlow';
import type { EsignContext, EsignReady } from '@/features/signing/types';
import type { ActionResult } from '@/features/forms/schemas';

// Form D signed on screen (0720, the owner's decision of November 7, 2026: no paper signature for anyone): the owner signs
// with the signing steps of every signature (a code to their phone or email, the reading, the consents, the signature);
// the two witnesses, beside the owner on the same device, each type their full name and tick the statement that they
// witnessed the owner sign in their presence. Part 2 is signed for CarmaCars from its stored signatures.
export interface FormDInput { method: 'typed' | 'drawn'; typedName?: string; witness1: string; witness2: string; statement: string; esign?: EsignReady }

const norm = (s: string) => s.replace(/\s+/g, '').toLowerCase();

export function FormDSignForm({ ownerName, statement, esign, action }: {
  ownerName: string; statement: string; esign: EsignContext; action: (input: FormDInput) => Promise<ActionResult<{ next: string }>>;
}) {
  const id = useId().replace(/[^\w-]/g, '');
  const router = useRouter();
  const [ready, setReady] = useState<EsignReady | null>(null);
  const [w1, setW1] = useState('');
  const [w2, setW2] = useState('');
  const [saw1, setSaw1] = useState(false);
  const [saw2, setSaw2] = useState(false);
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (!ready) fe.signature = 'Finish the owner\'s signing steps: the code, the reading, the consents and the signature.';
    for (const [k, v] of [['w1', w1], ['w2', w2]] as const) {
      if (v.trim().length < 3) fe[k] = 'The witness types their full name.';
      else if (norm(v) === norm(ownerName)) fe[k] = 'The witness is another adult, not the owner.';
    }
    if (!fe.w2 && w2.trim().length >= 3 && norm(w1) === norm(w2)) fe.w2 = 'The two witnesses are two different people.';
    if (!saw1) fe.saw1 = 'The first witness ticks the statement.';
    if (!saw2) fe.saw2 = 'The second witness ticks the statement.';
    setErrs(fe);
    if (Object.keys(fe).length) return;
    setBusy(true);
    try {
      const r = await action({ method: ready!.method, typedName: ready!.method === 'typed' ? ready!.typedName : undefined, witness1: w1.trim(), witness2: w2.trim(), statement, esign: ready! });
      if (!r.ok) { setErrs({ ...(r.fieldErrors ?? {}), form: r.fieldErrors ? '' : r.message }); return; }
      router.push(r.data.next);
    } catch (x) { setErrs({ form: x instanceof Error ? x.message : 'Something went wrong. Try again.' }); } finally { setBusy(false); }
  };
  const err = (k: string) => <p className="error" role="alert" id={`${id}-${k}-err`}>{errs[k] ?? ''}</p>;
  const witness = (n: 1 | 2, v: string, set: (s: string) => void, saw: boolean, setSaw: (b: boolean) => void) => {
    const k = `w${n}`, s = `saw${n}`;
    return (
      <fieldset className="stack"><legend className="d4">{n + 1}. Witness {n}, beside you on this device</legend>
        <div className={`field${errs[k] ? ' has-error' : ''}`}><label className="label" htmlFor={`${id}-${k}`}>Witness {n}, full name</label>
          <input className="input" id={`${id}-${k}`} value={v} onChange={(e) => set(e.target.value)} autoComplete="off" aria-invalid={!!errs[k] || undefined} aria-describedby={`${id}-${k}-err`} data-testid={`form-d-witness-${n}`} />{err(k)}</div>
        <label className="check"><input type="checkbox" checked={saw} onChange={(e) => setSaw(e.target.checked)} aria-invalid={!!errs[s] || undefined} aria-describedby={`${id}-${s}-err`} data-testid={`form-d-witness-${n}-statement`} /><span>{statement}</span></label>
        {err(s)}
      </fieldset>
    );
  };
  return (
    <form className="stack" onSubmit={submit} noValidate data-testid="form-d-sign">
      <fieldset className="stack"><legend className="d4">1. The owner signs</legend>
        <EsignFlow ctx={esign} terms={[]} docsLabel="Form D" onReady={(v) => { setReady(v); if (v) setErrs((x) => ({ ...x, signature: '' })); }} />
        {err('signature')}
      </fieldset>
      <p className="small muted">Hand the phone or computer to each witness in turn: two adults who watched you sign just now.</p>
      {witness(1, w1, setW1, saw1, setSaw1)}
      {witness(2, w2, setW2, saw2, setSaw2)}
      {errs.form && <p className="alert alert--error" role="alert"><span>{errs.form}</span></p>}
      <p className="xs muted">By pressing Sign, the owner signs Form D electronically and each witness confirms they saw it. We record the time, the IP address and the device. CarmaCars signs Part 2 from its stored signatures at the same moment.</p>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={busy || !ready} data-testid="form-d-submit">{busy ? 'Signing' : 'Sign Form D'}</button>
    </form>
  );
}
