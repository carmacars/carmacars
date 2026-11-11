'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from '@/components/Link';
import { opsAct } from '@/server/actions/ops';
import { describedBy, Field } from '@/features/forms/Field';
import { RenterIdentity } from './RenterIdentity';

// Release 34, section A (migration 0812): the profile card every portal has. The display name is changed at once. The legal
// name (the one on signed agreements and registry forms) is not edited freely: "Request a name change" asks an Admin, who
// approves in one tap. Email (ChangeEmail), phone (SignInSettings) and password (the reset page) sit beside it.
export interface SelfProfileData { user_id: string; email: string; display_name: string | null; account_name: string; legal_name: string; pending: { id: string; requested_name: string; requested_dob?: string | null; reason: string | null; requested_at: string } | null;
  /** r35 UX (1110): a renter: the date of birth, and whether a verified licence locks the name and the date of birth */ renter?: boolean; date_of_birth?: string | null; identity_locked?: boolean }

export function SelfProfile({ data, className = 'pt-card stack', password = true }: { data: SelfProfileData; className?: string; password?: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [display, setDisplay] = useState(data.display_name ?? '');
  const [asking, setAsking] = useState(false);
  const [name, setName] = useState('');
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string; where: 'display' | 'name' } | null>(null);
  const saveDisplay = () => start(async () => {
    setMsg(null);
    const r = await opsAct('display_name_save', { display_name: display });
    if (!r.ok) { setMsg({ ok: false, text: r.message, where: 'display' }); return; }
    setMsg({ ok: true, text: display.trim() ? `Saved. You are greeted as ${display.trim()}.` : 'Saved. Your name is used as it is on file.', where: 'display' });
    router.refresh();
  });
  const ask = () => start(async () => {
    setMsg(null);
    const r = await opsAct('name_change_request', { requested_name: name, reason });
    if (!r.ok) { setMsg({ ok: false, text: r.message, where: 'name' }); return; }
    setAsking(false); setName(''); setReason('');
    setMsg({ ok: true, text: 'Sent. An Admin reviews it and your name changes on your agreements once approved.', where: 'name' });
    router.refresh();
  });
  const err = (w: 'display' | 'name') => (msg && !msg.ok && msg.where === w ? msg.text : undefined);
  return (
    <section className={className} aria-labelledby="sp-t" data-testid="self-profile">
      <h2 className="d4" id="sp-t">Your name and password</h2>
      <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); saveDisplay(); }} aria-label="Display name">
        <Field id="sp-display" label="Display name" hint="How you are greeted in your portal. Not used on agreements." error={err('display')}>
          <input className="input" id="sp-display" value={display} maxLength={80} onChange={(e) => setDisplay(e.target.value)} aria-describedby={describedBy('sp-display', err('display'), true)} data-testid="sp-display" />
        </Field>
        <p><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="sp-display-save">{pending ? 'Saving' : 'Save my display name'}</button></p>
        {msg?.ok && msg.where === 'display' && <p className="alert alert--ok" role="status" data-testid="sp-display-msg"><span>{msg.text}</span></p>}
      </form>
      <dl className="pt-dl"><div><dt>Legal name</dt><dd data-testid="sp-legal">{data.legal_name}</dd></div></dl>
      {data.renter ? <RenterIdentity d={{ legal_name: data.legal_name, date_of_birth: data.date_of_birth ?? null, identity_locked: !!data.identity_locked, pending: data.pending }} />
        : data.pending
        ? <p className="small" role="status" data-testid="sp-pending">Name change waiting for an Admin: {data.pending.requested_name}.</p>
        : !asking
          ? <p className="small muted">The name on your signed agreements is changed by an Admin. <button type="button" className="btn btn--ghost btn--sm" onClick={() => { setAsking(true); setMsg(null); }} data-testid="sp-name-open">Request a name change</button></p>
          : <form className="stack" noValidate aria-label="Request a name change" onSubmit={(e) => { e.preventDefault(); ask(); }}>
            <Field id="sp-name" label="Full legal name" hint="As it should appear on your agreements." error={err('name')}>
              <input className="input" id="sp-name" value={name} onChange={(e) => setName(e.target.value)} aria-describedby={describedBy('sp-name', err('name'), true)} data-testid="sp-name" />
            </Field>
            <Field id="sp-reason" label="Why" hint="For example a marriage, a legal change or a typo.">
              <input className="input" id="sp-reason" value={reason} onChange={(e) => setReason(e.target.value)} data-testid="sp-reason" />
            </Field>
            <p className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending || !name.trim()} data-testid="sp-name-send">{pending ? 'Sending' : 'Send the request'}</button>
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setAsking(false); setMsg(null); }}>Cancel</button></p>
          </form>}
      {msg?.ok && msg.where === 'name' && <p className="alert alert--ok" role="status" data-testid="sp-name-msg"><span>{msg.text}</span></p>}
      {password && <p><Link prefetch={false} className="btn btn--ghost btn--sm" href="/reset-password" data-testid="sp-password">Change my password</Link></p>}
    </section>
  );
}
