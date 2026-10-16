'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { SignatureInput, type SignatureValue } from '@/features/signing/SignatureInput';
import type { ActionResult } from '@/features/forms/schemas';

// Form C signed on screen (the legal review, migration 0053): the owner initials the three acknowledgments and signs;
// the witness, beside the owner on the same device, types their full name and ticks the statement that they witnessed
// the owner sign in their presence. Form D stays on paper.
export interface FormCInput { method: 'typed' | 'drawn'; typedName?: string; drawn?: string; initials: string; acknowledgments: string[]; witnessName: string; witnessStatement: string }

const initialsOf = (name: string) => name.split(/\s+/).filter((w) => /^[A-Za-z]/.test(w)).map((w) => w[0]!.toUpperCase()).join('').slice(0, 4);

export function FormCSignForm({ ownerName, acknowledgments, statement, action }: {
  ownerName: string; acknowledgments: string[]; statement: string; action: (input: FormCInput) => Promise<ActionResult<{ next: string }>>;
}) {
  const id = useId().replace(/[^\w-]/g, '');
  const router = useRouter();
  const [ticked, setTicked] = useState<Set<number>>(new Set());
  const [ini, setIni] = useState(initialsOf(ownerName));
  const [sig, setSig] = useState<SignatureValue>(null);
  const [witness, setWitness] = useState('');
  const [saw, setSaw] = useState(false);
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const fe: Record<string, string> = {};
    if (ticked.size < acknowledgments.length) fe.acks = 'Initial each of the three acknowledgments (tick each one).';
    if (!/^[A-Za-z]{1,4}$/.test(ini.trim())) fe.initials = 'Your initials, letters only.';
    if (!sig) fe.signature = 'Draw your signature in the box, or use your name.';
    if (witness.trim().length < 3) fe.witness = 'The witness types their full name.';
    else if (witness.replace(/\s+/g, '').toLowerCase() === ownerName.replace(/\s+/g, '').toLowerCase()) fe.witness = 'The witness is another adult, not the owner.';
    if (!saw) fe.saw = 'The witness ticks the statement.';
    setErrs(fe);
    if (Object.keys(fe).length) return;
    setBusy(true);
    try {
      const r = await action({ method: sig!.method, typedName: sig!.method === 'typed' ? sig!.typedName : undefined, drawn: sig!.method === 'drawn' ? sig!.png : undefined,
        initials: ini.trim().toUpperCase(), acknowledgments: acknowledgments.map((_, i) => String(i + 1)), witnessName: witness.trim(), witnessStatement: statement });
      if (!r.ok) { setErrs({ ...(r.fieldErrors ?? {}), form: r.fieldErrors ? '' : r.message }); return; }
      router.push(r.data.next);
    } catch (x) { setErrs({ form: x instanceof Error ? x.message : 'Something went wrong. Try again.' }); } finally { setBusy(false); }
  };
  const err = (k: string) => errs[k] ? <p className="error" role="alert" id={`${id}-${k}-err`}>{errs[k]}</p> : <p className="error" role="alert" id={`${id}-${k}-err`} />;
  return (
    <form className="stack" onSubmit={submit} noValidate data-testid="form-c-sign">
      <fieldset className="stack"><legend className="d4">1. The owner initials</legend>
        {acknowledgments.map((a, i) => (
          <label className="check" key={i}><input type="checkbox" checked={ticked.has(i)} onChange={(e) => { const n = new Set(ticked); if (e.target.checked) n.add(i); else n.delete(i); setTicked(n); }}
            aria-invalid={!!errs.acks || undefined} aria-describedby={`${id}-acks-err`} data-testid={`form-c-ack-${i + 1}`} /><span>{a}</span></label>
        ))}
        {err('acks')}
        <div className={`field${errs.initials ? ' has-error' : ''}`} style={{ maxWidth: '10rem' }}><label className="label" htmlFor={`${id}-ini`}>Your initials</label>
          <input className="input" id={`${id}-ini`} value={ini} onChange={(e) => setIni(e.target.value)} autoComplete="off" maxLength={4} aria-invalid={!!errs.initials || undefined} aria-describedby={`${id}-initials-err`} data-testid="form-c-initials" />{err('initials')}</div>
      </fieldset>
      <fieldset className="stack"><legend className="d4">2. The owner signs</legend>
        <SignatureInput id={`${id}-sig`} name={ownerName} onChange={setSig} invalid={!!errs.signature} describedBy={`${id}-signature-err`} fixHref="/owner/profile" />
        {err('signature')}
      </fieldset>
      <fieldset className="stack"><legend className="d4">3. The witness, beside you on this device</legend>
        <p className="small muted">Hand the phone or computer to your witness: an adult who watched you sign just now.</p>
        <div className={`field${errs.witness ? ' has-error' : ''}`}><label className="label" htmlFor={`${id}-w`}>Witness, full name</label>
          <input className="input" id={`${id}-w`} value={witness} onChange={(e) => setWitness(e.target.value)} autoComplete="off" aria-invalid={!!errs.witness || undefined} aria-describedby={`${id}-witness-err`} data-testid="form-c-witness" />{err('witness')}</div>
        <label className="check"><input type="checkbox" checked={saw} onChange={(e) => setSaw(e.target.checked)} aria-invalid={!!errs.saw || undefined} aria-describedby={`${id}-saw-err`} data-testid="form-c-witness-statement" /><span>{statement}</span></label>
        {err('saw')}
      </fieldset>
      {errs.form && <p className="alert alert--error" role="alert"><span>{errs.form}</span></p>}
      <p className="xs muted">By pressing Sign, the owner signs Form C electronically and the witness confirms they saw it, each with the same effect as signing on paper. We record the time, the IP address and the device.</p>
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={busy} data-testid="form-c-submit">{busy ? 'Signing' : 'Sign Form C'}</button>
    </form>
  );
}
