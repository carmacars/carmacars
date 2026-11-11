'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { leadAct } from '@/server/actions/sales-leads';
import { claimWords, contactLinks, holdWords, OUTCOME_LABEL, OUTCOMES, type LeadRow, type Outcome, type Person } from './model';

type Msg = { ok: boolean; text: string } | null;

/** One lead's buttons: Claim or Unclaim, Call, Text and Email (each logged on the lead and extending the claim), a note,
 *  Mark handled, the outcome, and for an Admin Reassign. Phone-sized: the buttons wrap. */
export function LeadActions({ lead, admin, people, compact = false }: { lead: Pick<LeadRow, 'id' | 'phone' | 'email' | 'claim' | 'hold' | 'handled_at' | 'outcome'> & { assigned_to?: string | null }; admin: boolean; people: Person[]; compact?: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<Msg>(null);
  const [panel, setPanel] = useState<'note' | 'outcome' | 'reassign' | null>(null);
  const c = claimWords(lead.claim);
  const h = holdWords(lead.hold);
  const blocked = (c.locked || h.locked) && !admin;   // another person's claim, or a hold Sales may not work through
  const links = contactLinks(lead);
  const closed = Boolean(lead.handled_at) || lead.outcome === 'won' || lead.outcome === 'lost';
  const run = (action: string, p: Record<string, unknown>, ok?: string) => start(async () => {
    const r = await leadAct(action, { lead: lead.id, ...p });
    setMsg(r.ok ? (ok ? { ok: true, text: ok } : null) : { ok: false, text: r.message });
    if (r.ok) { setPanel(null); router.refresh(); }
  });
  // the phone or mail app opens at once; the contact is logged beside it
  const log = (channel: 'call' | 'text' | 'email') => () => { void leadAct('lead_contact', { lead: lead.id, channel }).then((r) => { if (!r.ok) setMsg({ ok: false, text: r.message }); else router.refresh(); }); };
  return (
    <div className="stack" style={{ gap: 'var(--s-2)' }} data-testid="lead-actions">
      {c.text && <p className={`small ${c.locked ? 'muted' : ''}`} data-testid="lead-claim">{c.text}</p>}
      {h.text && <p className={`small ${h.locked ? 'muted' : ''}`} data-testid="lead-hold" role="status">{h.text}</p>}
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        {!closed && !lead.claim && !lead.hold && <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={() => run('lead_claim', {})} data-testid="lead-claim-go">Claim</button>}
        {c.mine && <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('lead_unclaim', {}, 'Back in the pool.')} data-testid="lead-unclaim">Unclaim</button>}
        {admin && lead.claim && !c.mine && <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('lead_unclaim', { note: 'Released by an Admin' }, 'Released.')} data-testid="lead-release">Release</button>}
        {admin && lead.hold && h.text && <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('lead_hold_release', {}, 'Hold released.')} data-testid="lead-hold-release">Release hold</button>}
        {/* calls first, texts after (r37): Call leads; while the lead is held or claimed by someone else the links are off, with the reason */}
        {links.call && (h.locked && !admin ? <button type="button" className="btn btn--ghost btn--sm" disabled title={h.text ?? undefined} data-testid="lead-call">Call</button>
          : <a className="btn btn--ghost btn--sm" href={links.call} onClick={blocked ? undefined : log('call')} data-testid="lead-call">Call</a>)}
        {links.text && (h.locked && !admin ? <button type="button" className="btn btn--ghost btn--sm" disabled title={h.text ?? undefined} data-testid="lead-text">Text</button>
          : <a className="btn btn--ghost btn--sm" href={links.text} onClick={blocked ? undefined : log('text')} data-testid="lead-text">Text</a>)}
        {links.email && (h.locked && !admin ? <button type="button" className="btn btn--ghost btn--sm" disabled title={h.text ?? undefined} data-testid="lead-email">Email</button>
          : <a className="btn btn--ghost btn--sm" href={links.email} onClick={blocked ? undefined : log('email')} data-testid="lead-email">Email</a>)}
        {!compact && <button type="button" className="btn btn--ghost btn--sm" disabled={pending || blocked} onClick={() => setPanel(panel === 'note' ? null : 'note')} data-testid="lead-note">Note</button>}
        {!closed && <button type="button" className="btn btn--ghost btn--sm" disabled={pending || blocked} onClick={() => run('lead_handled', {}, 'Marked handled.')} data-testid="lead-handled">Mark handled</button>}
        {lead.handled_at && lead.outcome !== 'won' && lead.outcome !== 'lost' && <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('lead_handled', { undo: true }, 'Open again.')}>Open again</button>}
        <button type="button" className="btn btn--ghost btn--sm" disabled={pending || blocked} onClick={() => setPanel(panel === 'outcome' ? null : 'outcome')} data-testid="lead-outcome">Outcome</button>
        {admin && <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => setPanel(panel === 'reassign' ? null : 'reassign')} data-testid="lead-reassign">Reassign</button>}
        {/* 1151: back to the salesperson who brought or last had it (else the pool) */}
        {admin && (lead.claim || lead.assigned_to) && <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('lead_return', {}, 'Returned to the previous owner.')} data-testid="lead-return">Return lead to previous owner</button>}
      </div>
      {panel === 'note' && <form className="stack" onSubmit={(e) => { e.preventDefault(); const note = String(new FormData(e.currentTarget).get('note') ?? ''); run('lead_contact', { channel: 'note', note }, 'Note saved.'); }}>
        <label className="small" htmlFor={`ln-${lead.id}`}>Note</label>
        <textarea className="input" id={`ln-${lead.id}`} name="note" rows={2} maxLength={1000} required />
        <button className="btn btn--primary btn--sm" type="submit" disabled={pending}>Save note</button></form>}
      {panel === 'outcome' && <OutcomeForm id={lead.id} pending={pending} onSave={(p) => run('lead_outcome', p, 'Saved.')} />}
      {panel === 'reassign' && <form className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }} onSubmit={(e) => { e.preventDefault(); run('lead_reassign', { to: String(new FormData(e.currentTarget).get('to') ?? '') }, 'Reassigned.'); }}>
        <label className="vh" htmlFor={`lr-${lead.id}`}>Give the lead to</label>
        <select className="input" id={`lr-${lead.id}`} name="to" required defaultValue=""><option value="" disabled>Give it to</option>{people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select>
        <button className="btn btn--primary btn--sm" type="submit" disabled={pending}>Reassign</button></form>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}

function OutcomeForm({ id, pending, onSave }: { id: string; pending: boolean; onSave: (p: Record<string, unknown>) => void }) {
  const [o, setO] = useState<Outcome>('contacted');
  return (
    <form className="stack" onSubmit={(e) => { e.preventDefault(); const f = new FormData(e.currentTarget); onSave({ outcome: o, reason: f.get('reason') ?? '', booking: f.get('booking') ?? '' }); }}>
      <label className="small" htmlFor={`lo-${id}`}>Outcome</label>
      <select className="input" id={`lo-${id}`} value={o} onChange={(e) => setO(e.target.value as Outcome)}>{OUTCOMES.map((x) => <option key={x} value={x}>{OUTCOME_LABEL[x]}</option>)}</select>
      {o === 'lost' && <><label className="small" htmlFor={`lw-${id}`}>Why it was lost</label><input className="input" id={`lw-${id}`} name="reason" maxLength={300} required /></>}
      {o === 'won' && <><label className="small" htmlFor={`lb-${id}`}>Booking number (optional)</label><input className="input" id={`lb-${id}`} name="booking" maxLength={40} /></>}
      <button className="btn btn--primary btn--sm" type="submit" disabled={pending}>Save outcome</button>
    </form>
  );
}

/** Next lead: claims the oldest hot lead nobody holds and opens it. */
export function NextLead({ base, type }: { base: string; type?: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  return (
    <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
      <button type="button" className="btn btn--primary btn--sm" disabled={pending} data-testid="lead-next"
        onClick={() => start(async () => { const r = await leadAct<{ lead: string | null }>('lead_next', type ? { type } : {}); if (!r.ok) { setMsg(r.message); return; } if (!r.data.lead) { setMsg('No open lead waiting: well done.'); return; } router.push(`${base}/${r.data.lead}`); })}>Next lead</button>
      {msg && <span className="small" role="status">{msg}</span>}
    </span>
  );
}
