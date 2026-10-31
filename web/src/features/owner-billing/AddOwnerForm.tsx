'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { addOwner } from '@/server/actions/owner-billing';

// Owners > Add an owner (0264): on file without a car, with the owner's default terms if agreed. Nothing is emailed
// unless "Invite the owner now" is ticked.
const cents = (s: string) => (s.trim() === '' ? null : Math.round(Number(s.replace(/[$,\s]/g, '')) * 100));
const bps = (s: string) => (s.trim() === '' ? null : Math.round(Number(s.replace(/[%\s]/g, '')) * 100));

export function AddOwnerForm() {
  const uid = useId();
  const router = useRouter();
  const [pending, start] = useTransition();
  const [f, setF] = useState({ legal_name: '', email: '', phone: '', owner_type: 'individual', corporation_name: '', ins: '', trk: '', share: '' });
  const [invite, setInvite] = useState(false);
  const [err, setErr] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  const field = (k: keyof typeof f, label: string, opts: { type?: string; hint?: string; mode?: 'email' | 'tel' | 'decimal' } = {}) => (
    <div className={`field${err[k] ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-${k}`}>{label}</label>
      <input className="input" id={`${uid}-${k}`} type={opts.type ?? 'text'} inputMode={opts.mode} value={f[k]} onChange={set(k)} data-testid={`addowner-${k}`} />
      {opts.hint && <p className="hint">{opts.hint}</p>}<p className="error" role="alert">{err[k] ?? ''}</p></div>);
  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    setMsg(null); setErr({});
    start(async () => {
      const r = await addOwner({ legal_name: f.legal_name, email: f.email.trim() || undefined, phone: f.phone.trim() || undefined, owner_type: f.owner_type as 'individual' | 'corporation',
        corporation_name: f.corporation_name || undefined, terms: { insurance_fee_cents: cents(f.ins), tracker_fee_cents: cents(f.trk), revenue_share_bps: bps(f.share) }, invite });
      if (!r.ok) { setErr(r.fieldErrors ?? {}); setMsg({ ok: false, text: r.message }); return; }
      setMsg({ ok: true, text: r.data.note ?? 'Added. Nothing was emailed: invite the owner when ready.' });
      router.push(`/admin/owners/${r.data.owner_id}`);
    });
  };
  return (
    <form className="stack" noValidate onSubmit={submit} data-testid="addowner-form">
      {field('legal_name', 'Full legal name')}
      {field('email', 'Email', { type: 'email', mode: 'email' })}
      {field('phone', 'Phone (optional when there is an email)', { type: 'tel', mode: 'tel' })}
      <div className="field"><label className="label" htmlFor={`${uid}-type`}>The owner is</label>
        <select className="select" id={`${uid}-type`} value={f.owner_type} onChange={set('owner_type')} data-testid="addowner-owner_type"><option value="individual">An individual</option><option value="corporation">A corporation</option></select></div>
      {f.owner_type === 'corporation' && field('corporation_name', 'Corporation name')}
      <fieldset className="stack"><legend className="label">Terms agreed (optional, an Admin)</legend>
        {field('ins', 'Insurance Fee ($ per month)', { mode: 'decimal' })}{field('trk', 'Tracker Fee ($ per month)', { mode: 'decimal' })}{field('share', 'Revenue Share to the owner (%)', { mode: 'decimal' })}
        <p className="hint">Empty: the standard terms. They become the default for the owner&apos;s cars.</p></fieldset>
      <label className="check"><input type="checkbox" checked={invite} onChange={(e) => setInvite(e.target.checked)} data-testid="addowner-invite" /> <span>Invite the owner now (they get an email to choose a password). Unticked: nothing is sent.</span></label>
      <button className="btn btn--primary" type="submit" disabled={pending} data-testid="addowner-save">{pending ? 'Saving' : 'Add the owner'}</button>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </form>
  );
}
