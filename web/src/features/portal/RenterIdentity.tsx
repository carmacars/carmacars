'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import { describedBy, Field } from '@/features/forms/Field';
import { identityMode } from './identity';

// r35 UX (1110): a renter's legal name and date of birth. Saved at once while no licence of theirs is verified; once one is,
// a change is a correction that Sales, customer service or an Admin check against the licence (the date of birth decides the
// young driver fee and the insurer's eligibility). Email and phone are changed under Sign-in, with their own checks.
export interface RenterIdentityData { legal_name: string; date_of_birth: string | null; identity_locked: boolean;
  pending: { requested_name: string; requested_dob?: string | null } | null }

export function RenterIdentity({ d }: { d: RenterIdentityData }) {
  const router = useRouter();
  const [busy, start] = useTransition();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState(d.legal_name);
  const [dob, setDob] = useState(d.date_of_birth ?? '');
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const mode = identityMode(d);
  const save = () => start(async () => {
    setMsg(null);
    const r = await opsAct<{ saved?: boolean; pending?: boolean }>('profile_identity_save', { legal_name: name, date_of_birth: dob, reason });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setOpen(false); setReason('');
    setMsg({ ok: true, text: r.data.pending ? 'Sent. Our team checks it against your licence; your details change once approved.' : 'Saved.' });
    router.refresh();
  });
  const err = msg && !msg.ok ? msg.text : undefined;
  return (
    <div className="stack" data-testid="renter-identity">
      <dl className="pt-dl"><div><dt>Date of birth</dt><dd data-testid="ri-dob">{d.date_of_birth ?? 'Not given yet'}</dd></div></dl>
      {mode === 'pending' && <p className="small" role="status" data-testid="ri-pending">Correction waiting to be checked against your licence: {d.pending!.requested_name}{d.pending!.requested_dob ? `, born ${d.pending!.requested_dob}` : ''}.</p>}
      {mode !== 'pending' && !open && <p className="small muted">{mode === 'edit' ? 'You can change your name and date of birth until your licence is verified.' : 'Your licence is verified: a change is checked against it by our team.'}{' '}
        <button type="button" className="btn btn--ghost btn--sm" onClick={() => { setOpen(true); setMsg(null); }} data-testid="ri-open">{mode === 'edit' ? 'Edit my name and date of birth' : 'Ask for a correction'}</button></p>}
      {open && (
        <form className="stack" noValidate aria-label="Name and date of birth" onSubmit={(e) => { e.preventDefault(); save(); }}>
          <Field id="ri-name" label="Full legal name" hint="As on your driver's licence." error={err}>
            <input className="input" id="ri-name" value={name} onChange={(e) => setName(e.target.value)} aria-describedby={describedBy('ri-name', err, true)} data-testid="ri-name" />
          </Field>
          <Field id="ri-dob-in" label="Date of birth" hint="As on your driver's licence.">
            <input className="input" id="ri-dob-in" type="date" value={dob} onChange={(e) => setDob(e.target.value)} data-testid="ri-dob-input" />
          </Field>
          {mode === 'request' && <Field id="ri-reason" label="Why it changes" hint="For example a typo or a legal name change.">
            <input className="input" id="ri-reason" value={reason} onChange={(e) => setReason(e.target.value)} data-testid="ri-reason" />
          </Field>}
          <p className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={busy} data-testid="ri-save">{busy ? 'Saving' : mode === 'edit' ? 'Save' : 'Send the correction'}</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button></p>
        </form>)}
      {msg?.ok && <p className="alert alert--ok" role="status" data-testid="ri-msg"><span>{msg.text}</span></p>}
    </div>
  );
}
