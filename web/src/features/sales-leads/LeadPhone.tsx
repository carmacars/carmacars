'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { leadAct } from '@/server/actions/sales-leads';
import { CopyLink } from '@/features/portal/CopyLink';
import { t } from '@/features/admin/ui';
import { phoneMasked, phoneOwner, type LeadRow, type Person } from './model';

/** A lead's phone: masked as Sales is shown it (0970), or in full with a call link and Copy (an Admin, customer service,
 *  or a salesperson an Admin showed it to, 2870). */
export function PhoneValue({ phone, testId = 'lead-phone' }: { phone: string | null; testId?: string }) {
  if (!phone) return <span className="muted">none</span>;
  if (phoneMasked(phone)) return <span className="num" data-testid={testId}>{phone}</span>;
  return (
    <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', display: 'inline-flex' }}>
      <a className="link num" href={`tel:${phone.replace(/[^\d+]/g, '')}`} data-testid={testId}>{phone}</a>
      <CopyLink url={phone} label="Copy" done="Copied" ariaLabel="Copy the phone number" testId={`${testId}-copy`} />
    </span>
  );
}

type Lead = Pick<LeadRow, 'id' | 'phone' | 'assigned_to' | 'assigned_name' | 'claim' | 'phone_unlocks' | 'phone_unlocked' | 'phone_ask_open'>;

/** 2870: Show the phone to a salesperson (an Admin, lead by lead), Hide it again; for Sales, the badge and Ask an Admin to
 *  show the number. `people` (the lead page) lets the Admin choose another Sales person and give a reason. */
export function LeadPhoneAccess({ lead, admin, people, compact = false }: { lead: Lead; admin: boolean; people?: Person[]; compact?: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [open, setOpen] = useState(false);
  if (!lead.phone) return null;
  const owner = phoneOwner(lead);
  const shown = lead.phone_unlocks ?? [];
  const run = (action: string, p: Record<string, unknown>, ok: string) => start(async () => {
    const r = await leadAct(action, { lead: lead.id, ...p });
    setMsg(r.ok ? { ok: true, text: ok } : { ok: false, text: r.message });
    if (r.ok) { setOpen(false); router.refresh(); }
  });
  const note = msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>;

  if (!admin) {
    if (lead.phone_unlocked) return <p className="small" data-testid="lead-phone-unlocked"><span className="badge badge--outline">Number shown by an Admin</span> for this lead only.</p>;
    if (!phoneMasked(lead.phone)) return null;
    return (
      <div className="stack" style={{ gap: 'var(--s-1)' }}>
        {lead.phone_ask_open
          ? <p className="small muted" data-testid="lead-phone-asked">Asked: an Admin has a To do to show you the number.</p>
          : <span><button type="button" className="btn btn--quiet btn--sm" disabled={pending} data-testid="lead-phone-ask"
              onClick={() => run('lead_phone_ask', {}, 'Asked. An Admin has a To do on this lead.')}>Ask an Admin to show the number</button></span>}
        {note}
      </div>
    );
  }

  const choices = people ?? [];
  const already = new Set(shown.map((s) => s.to));
  const ownerDone = owner ? already.has(owner.id) : false;
  return (
    <div className="stack" style={{ gap: 'var(--s-1)' }} data-testid="lead-phone-access">
      {shown.map((s) => (
        <p key={s.to} className="small row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }} data-testid="lead-phone-shown">
          <span>Phone shown in full to <b>{s.name}</b> since {t(s.at)} (by {s.by}){s.reason ? `: ${s.reason}` : ''}.</span>
          <button type="button" className="btn btn--ghost btn--sm" disabled={pending} data-testid="lead-phone-hide"
            onClick={() => run('lead_phone_hide', { to: s.to }, 'Hidden again.')}>Hide it again</button>
        </p>))}
      {lead.phone_ask_open && <p className="small" data-testid="lead-phone-asked">A salesperson asked to see this number.</p>}
      <div className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
        {owner && !ownerDone && (compact || !choices.length)
          ? <button type="button" className="btn btn--ghost btn--sm" disabled={pending} data-testid="lead-phone-show"
              onClick={() => run('lead_phone_unlock', { to: owner.id }, `Shown to ${owner.name}.`)}>Show the phone to {owner.name}</button>
          : !compact && choices.length > 0 && <button type="button" className="btn btn--ghost btn--sm" disabled={pending} data-testid="lead-phone-show"
              onClick={() => setOpen(!open)}>{owner && !ownerDone ? `Show the phone to ${owner.name}` : 'Show the phone to a salesperson'}</button>}
      </div>
      {open && !compact && (
        <form className="stack" style={{ gap: 'var(--s-1)' }} onSubmit={(e) => { e.preventDefault(); const f = new FormData(e.currentTarget);
          run('lead_phone_unlock', { to: String(f.get('to') ?? ''), reason: String(f.get('reason') ?? '') }, 'Shown.'); }}>
          <label className="small" htmlFor={`lpt-${lead.id}`}>Show the full number to</label>
          <select className="input" id={`lpt-${lead.id}`} name="to" required defaultValue={owner && !ownerDone ? owner.id : ''}>
            <option value="" disabled>Choose a salesperson</option>
            {choices.filter((p) => !already.has(p.id)).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
          <label className="small" htmlFor={`lpr-${lead.id}`}>Reason (optional, kept in the audit log)</label>
          <input className="input" id={`lpr-${lead.id}`} name="reason" maxLength={300} />
          <span><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="lead-phone-show-go">Show the phone</button></span>
        </form>)}
      {note}
    </div>
  );
}
