'use client';
import { useRouter } from 'next/navigation';
import { useState, useTransition } from 'react';
import { inviteAccount, sendPasswordLink } from '@/server/actions/admin-portal';

// Sign-in tools for Admins: invite a person into any role, and send anyone the link to choose a password.

export function PasswordLinkButton({ userId, label = 'Send password link', testId }: { userId: string; label?: string; testId?: string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (
    <span className="row" style={{ display: 'inline-flex', gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'center' }}>
      <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={testId}
        onClick={() => { if (!window.confirm('Email this person a link to choose a password? It works for 24 hours.')) return; start(async () => { const r = await sendPasswordLink(userId); setMsg(r.ok ? { ok: true, text: `Sent to ${r.data.email}.` } : { ok: false, text: r.message }); }); }}>
        {pending ? 'Sending' : label}</button>
      {msg && <span className={msg.ok ? 'small' : 'ad-err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</span>}
    </span>
  );
}

/** One click: a sign-in for an owner or investor on file, with the invitation email to their address. */
export function InviteRecordButton({ role, recordId, email, name, testId }: { role: 'owner' | 'investor'; recordId: string; email: string | null; name: string; testId?: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  if (!email) return <span className="small muted">Add an email to invite</span>;
  return (
    <span className="row" style={{ display: 'inline-flex', gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'center' }}>
      <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={testId}
        onClick={() => { if (!window.confirm(`Invite ${name} (${email}) to the ${role} portal? They get an email with a link to choose a password.`)) return; start(async () => {
          const r = await inviteAccount({ role, email, full_name: name, owner_id: role === 'owner' ? recordId : undefined, investor_id: role === 'investor' ? recordId : undefined });
          setMsg(r.ok ? { ok: true, text: r.data.existed ? 'They already sign in: linked, no email sent.' : `Invitation sent to ${r.data.email}.` } : { ok: false, text: r.message });
          if (r.ok) router.refresh(); }); }}>
        {pending ? 'Inviting' : `Invite to the ${role} portal`}</button>
      {msg && <span className={msg.ok ? 'small' : 'ad-err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</span>}
    </span>
  );
}

type Rec = { id: string; name: string; email: string | null };
// the kinds of staff work (0197): any combination, in one staff portal
const FNS: Array<[string, string]> = [['cs', 'Customer service'], ['sales', 'Sales'], ['fleet', 'Fleet'], ['finance', 'Finance'], ['field', 'Field work']];

export function InviteForm({ owners = [], investors = [], roles = ['staff', 'owner', 'investor'], testId = 'invite-form' }: { owners?: Rec[]; investors?: Rec[]; roles?: string[]; testId?: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [f, setF] = useState({ email: '', full_name: '', role: roles[0] ?? 'staff', functions: ['cs'] as string[], sales_work_mode: 'in_person', field_function: 'driver_detailer', owner_id: '', investor_id: '' });
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [errs, setErrs] = useState<Record<string, string>>({});
  const pickRecord = (kind: 'owner' | 'investor', id: string) => {
    const r = (kind === 'owner' ? owners : investors).find((x) => x.id === id);
    setF({ ...f, [`${kind}_id`]: id, email: r?.email ?? f.email, full_name: r?.name ?? f.full_name });
  };
  const submit = () => start(async () => {
    const staff = f.role === 'staff';
    const r = await inviteAccount({ email: f.email, full_name: f.full_name, role: f.role, functions: staff ? f.functions : undefined,
      work_mode: staff && f.functions.includes('sales') ? f.sales_work_mode as 'in_person' | 'remote' : undefined, field_function: staff && f.functions.includes('field') ? f.field_function : undefined,
      owner_id: f.role === 'owner' ? f.owner_id : undefined, investor_id: f.role === 'investor' ? f.investor_id : undefined });
    if (r.ok) {
      setErrs({});
      setMsg({ ok: true, text: r.data.existed ? `${r.data.email} already signs in to CarmaCars: the role is added and no email was sent. Use Send password link if they need one.` : `Invitation sent to ${r.data.email}. The link works for 24 hours; send a new one from the list if it runs out.` });
      setF({ ...f, email: '', full_name: '', owner_id: '', investor_id: '' });
      router.refresh();
    } else { setErrs((r as { fieldErrors?: Record<string, string> }).fieldErrors ?? {}); setMsg({ ok: false, text: r.message }); }
  });
  const err = (k: string) => errs[k] ? <p className="error" role="alert" id={`inv-${k}-err`}>{errs[k]}</p> : null;
  return (
    <form className="ad-form" data-testid={testId} noValidate onSubmit={(e) => { e.preventDefault(); submit(); }}>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="inv-r">Role</label>
          <select className="select" id="inv-r" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}>
            {roles.includes('staff') && <option value="staff">Staff</option>}
            {roles.includes('owner') && <option value="owner">Owner on file</option>}
            {roles.includes('investor') && <option value="investor">Investor on file</option>}
          </select>{err('role')}<p className="small muted">Admin access is only through rent@carmacars.ca (Settings &gt; Staff and roles &gt; Admin access).</p></div>
        {f.role === 'owner' && <div className="field ad-field"><label className="label" htmlFor="inv-o">Owner</label>
          <select className="select" id="inv-o" value={f.owner_id} onChange={(e) => pickRecord('owner', e.target.value)} aria-invalid={!!errs.owner_id || undefined}>
            <option value="">{owners.length ? 'Choose an owner without a sign-in' : 'Every owner on file has a sign-in'}</option>
            {owners.map((o) => <option key={o.id} value={o.id}>{o.name}{o.email ? ` (${o.email})` : ''}</option>)}
          </select>{err('owner_id')}<p className="small muted">A new owner applies first: Admin &gt; Owners &gt; Invite an owner.</p></div>}
        {f.role === 'investor' && <div className="field ad-field"><label className="label" htmlFor="inv-i">Investor</label>
          <select className="select" id="inv-i" value={f.investor_id} onChange={(e) => pickRecord('investor', e.target.value)} aria-invalid={!!errs.investor_id || undefined}>
            <option value="">{investors.length ? 'Choose an investor without a sign-in' : 'Every investor on file has a sign-in'}</option>
            {investors.map((o) => <option key={o.id} value={o.id}>{o.name}{o.email ? ` (${o.email})` : ''}</option>)}
          </select>{err('investor_id')}</div>}
        <div className="field ad-field"><label className="label" htmlFor="inv-n">Name</label><input className="input" id="inv-n" value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} aria-invalid={!!errs.full_name || undefined} />{err('full_name')}</div>
        <div className="field ad-field"><label className="label" htmlFor="inv-e">Email</label><input className="input" id="inv-e" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} aria-invalid={!!errs.email || undefined} />{err('email')}</div>
        {f.role === 'staff' && <fieldset className="field ad-field" data-testid="inv-functions"><legend className="label">Staff work</legend>
          {FNS.map(([k, l]) => <label key={k} className="check"><input type="checkbox" value={k} checked={f.functions.includes(k)} onChange={(e) => setF({ ...f, functions: e.target.checked ? [...f.functions, k] : f.functions.filter((c) => c !== k) })} /><span className="small">{l}</span></label>)}{err('functions')}</fieldset>}
        {f.role === 'staff' && f.functions.includes('sales') && <div className="field ad-field"><label className="label" htmlFor="inv-m">Sales work</label>
          <select className="select" id="inv-m" value={f.sales_work_mode} onChange={(e) => setF({ ...f, sales_work_mode: e.target.value })}>
            <option value="in_person">In person</option><option value="remote">Remote</option></select></div>}
        {f.role === 'staff' && f.functions.includes('field') && <div className="field ad-field"><label className="label" htmlFor="inv-f">Field role</label>
          <select className="select" id="inv-f" value={f.field_function} onChange={(e) => setF({ ...f, field_function: e.target.value })}>
            <option value="driver">Driver</option><option value="detailer">Detailer</option><option value="driver_detailer">Driver and detailer</option></select>{err('field_function')}</div>}
      </div>
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending}>{pending ? 'Inviting' : 'Invite'}</button>{msg && <span className={msg.ok ? 'small' : 'ad-err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</span>}</div>
    </form>
  );
}
