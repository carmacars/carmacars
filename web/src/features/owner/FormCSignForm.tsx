'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { EsignFlow } from '@/features/signing/EsignFlow';
import { formCTerms } from '@/features/signing/terms';
import { initialsOf } from '@/features/signing/PackageSignForm';
import type { EsignContext, EsignReady } from '@/features/signing/types';
import type { ActionResult } from '@/features/forms/schemas';

// Form C signed on screen (the legal review, migration 0053): the owner signs with the signing steps of every signature
// (0193: a code to their phone or email, the reading, the three acknowledgments initialled, the consents, the drawn
// signature); the witness, beside the owner on the same device, types their full name and ticks the statement that they
// witnessed the owner sign in their presence. Form D stays on paper.
export interface FormCInput { method: 'typed' | 'drawn'; typedName?: string; drawn?: string; initials: string; acknowledgments: string[]; witnessName: string; witnessStatement: string; esign?: EsignReady }

export function FormCSignForm({ ownerName, acknowledgments, statement, esign, action }: {
  ownerName: string; acknowledgments: string[]; statement: string; esign: EsignContext; action: (input: FormCInput) => Promise<ActionResult<{ next: string }>>;
}) {
  const id = useId().replace(/[^\w-]/g, '');
  const router = useRouter();
  const [ready, setReady] = useState<EsignReady | null>(null);
  const [witness, setWitness] = useState('');
  const [saw, setSaw] = useState(false);
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (!ready) fe.signature = 'Finish the owner\'s signing steps: the code, the reading, the initials, the consents and the signature.';
    if (witness.trim().length < 3) fe.witness = 'The witness types their full name.';
    else if (witness.replace(/\s+/g, '').toLowerCase() === ownerName.replace(/\s+/g, '').toLowerCase()) fe.witness = 'The witness is another adult, not the owner.';
    if (!saw) fe.saw = 'The witness ticks the statement.';
    setErrs(fe);
    if (Object.keys(fe).length) return;
    setBusy(true);
    try {
      const r = await action({ method: ready!.method, typedName: ready!.method === 'typed' ? ready!.typedName : undefined, initials: initialsOf(ownerName),
        acknowledgments: acknowledgments.map((_, i) => String(i + 1)), witnessName: witness.trim(), witnessStatement: statement, esign: ready! });
      if (!r.ok) { setErrs({ ...(r.fieldErrors ?? {}), form: r.fieldErrors ? '' : r.message }); return; }
      router.push(r.data.next);
    } catch (x) { setErrs({ form: x instanceof Error ? x.message : 'Something went wrong. Try again.' }); } finally { setBusy(false); }
  };
  const err = (k: string) => errs[k] ? <p className="error" role="alert" id={`${id}-${k}-err`}>{errs[k]}</p> : <p className="error" role="alert" id={`${id}-${k}-err`} />;
  return (
    <form className="stack" onSubmit={submit} noValidate data-testid="form-c-sign">
      <fieldset className="stack"><legend className="d4">1. The owner signs</legend>
        <EsignFlow ctx={esign} terms={formCTerms(acknowledgments)} docsLabel="Form C" onReady={(v) => { setReady(v); if (v) setErrs((x) => ({ ...x, signature: '' })); }} />
        {err('signature')}
      </fieldset>
      <fieldset className="stack"><legend className="d4">2. The witness, beside you on this device</legend>
        <p className="small muted">Hand the phone or computer to your witness: an adult who watched you sign just now.</p>
        <div className={`field${errs.witness ? ' has-error' : ''}`}><label className="label" htmlFor={`${id}-w`}>Witness, full name</label>
          <input className="input" id={`${id}-w`} value={witness} onChange={(e) => setWitness(e.target.value)} autoComplete="off" aria-invalid={!!errs.witness || undefined} aria-describedby={`${id}-witness-err`} data-testid="form-c-witness" />{err('witness')}</div>
        <label className="check"><input type="checkbox" checked={saw} onChange={(e) => setSaw(e.target.checked)} aria-invalid={!!errs.saw || undefined} aria-describedby={`${id}-saw-err`} data-testid="form-c-witness-statement" /><span>{statement}</span></label>
        {err('saw')}
      </fieldset>
      {errs.form && <p className="alert alert--error" role="alert"><span>{errs.form}</span></p>}
      <p className="xs muted">By pressing Sign, the owner signs Form C electronically and the witness confirms they saw it, each with the same effect as signing on paper. We record the time, the IP address and the device.</p>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={busy || !ready} data-testid="form-c-submit">{busy ? 'Signing' : 'Sign Form C'}</button>
    </form>
  );
}
