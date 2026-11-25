'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { payIdentityReveal, spendDo } from '@/server/actions/field-work';

// Finance and Admin (r35 part X; 0930, 0931): money field staff spent, to approve or refuse and to pay back, and who has not entered
// their pay details. The SIN and the void cheque open only with a reason, and the database logs each view first.
export interface SpendRow { id: string; staff: string; kind: string; spent_on: string; description: string; amount_cents: number; hst_cents: number; vehicle: string | null; booking: string | null;
  paid_with: 'own' | 'company'; status: string; note: string | null; receipt_url: string | null; service: boolean }
export interface PayIdRow { user_id: string; name: string; legal_name: string | null; email: string | null; phone: string | null; sin: string | null; cheque: boolean; complete: boolean; missing: string[] }
const STATUS: Record<string, string> = { submitted: 'Waiting', approved: 'Approved', refused: 'Declined', reimbursed: 'Paid back' };

function SpendActions({ r }: { r: SpendRow }) {
  const router = useRouter();
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const go = (action: 'field_spend_decide' | 'field_spend_paid_back', approve?: boolean) => start(async () => {
    setErr(null);
    // r50: a decline always says why (the person is told)
    if (approve === false && note.trim().length < 3) { setErr('Say why it is declined: they see the reason.'); return; }
    const x = await spendDo(action, { id: r.id, approve, note });
    if (!x.ok) { setErr(x.message); return; }
    router.refresh();
  });
  return (
    <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-1)' }}>
      {r.status === 'submitted' && <>
        <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={() => go('field_spend_decide', true)} data-testid={`spend-approve-${r.id}`}>Approve</button>
        <input className="input" style={{ maxWidth: '12rem' }} placeholder="Why declined" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Why declined" data-testid={`spend-reason-${r.id}`} />
        <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => go('field_spend_decide', false)} data-testid={`spend-decline-${r.id}`}>Decline</button></>}
      {r.status === 'approved' && r.paid_with === 'own' && <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={() => go('field_spend_paid_back')} data-testid={`spend-paid-${r.id}`}>Mark paid back</button>}
      {err && <span className="error" role="alert">{err}</span>}
    </div>
  );
}

export function SpendingPanel({ rows }: { rows: SpendRow[] }) {
  return (
    <section className="ad-card stack" aria-labelledby="fs-h" data-testid="field-spending" data-guide="field-spending">
      <h2 className="d4" id="fs-h">Field spending to approve or pay back</h2>
      {rows.length === 0 ? <p className="small muted">Nothing waiting.</p> : <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Table"><table className="ad-table ad-table--dense"><thead><tr><th>Who</th><th>What</th><th>Amount</th><th>Receipt</th><th>Status</th><th /></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.id}><td>{r.staff}<br /><span className="small muted">{r.spent_on}</span></td>
          <td>{r.description}{r.vehicle ? <><br /><span className="small muted">{r.vehicle}{r.booking ? `, ${r.booking}` : ''}</span></> : null}{r.service ? <><br /><span className="small">Service: already on the car</span></> : null}</td>
          <td>{money(r.amount_cents + r.hst_cents, { cents: true })}<br /><span className="small muted">{r.paid_with === 'own' ? 'Their own money: pay back' : 'Company card/cash'}</span></td>
          <td>{r.receipt_url ? <a className="link" href={r.receipt_url} target="_blank" rel="noreferrer">Open</a> : <span className="small">Missing</span>}</td>
          <td>{STATUS[r.status] ?? r.status}{r.note ? <><br /><span className="small muted">{r.note}</span></> : null}</td><td><SpendActions r={r} /></td></tr>)}</tbody></table></div>}
    </section>
  );
}

/** r50 (3720): what is owed back to staff who paid with their own money, per person: the payroll's payout list. */
export interface OwedPerson { staff_id: string; name: string; owed_cents: number | null; pending_cents: number; items: Array<{ id: string; spend_id: string | null; description: string; amount_cents: number; status: string }> }
function PaidBack({ id, label }: { id: string; label: string }) {
  const router = useRouter();
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (<span className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-1)' }}>
    <button type="button" className="btn btn--ghost btn--sm" disabled={pending} data-testid={`reimb-paid-${id}`} onClick={() => start(async () => {
      setErr(null);
      const x = await spendDo('reimbursement_paid', { id });
      if (!x.ok) { setErr(x.message); return; }
      router.refresh();
    })}>{pending ? 'Saving' : label}</button>{err && <span className="error" role="alert">{err}</span>}</span>);
}
export function ReimbursementsPanel({ owedCents, people }: { owedCents: number; people: OwedPerson[] }) {
  return (
    <section className="ad-card stack" aria-labelledby="rb-h" data-testid="reimbursements" data-guide="reimbursements">
      <h2 className="d4" id="rb-h">Reimbursements owed: {money(owedCents, { cents: true })}</h2>
      <p className="small muted">Staff who paid with their own money. Approved items are owed and paid back with their pay; waiting items are still with Finance.</p>
      {people.length === 0 ? <p className="small muted">Nothing owed.</p> : <ul className="stack" role="list">{people.map((x) => (
        <li key={x.staff_id} className="stack" style={{ gap: 'var(--s-1)' }} data-testid={`reimb-${x.staff_id}`}>
          <p><b>{x.name}</b>: {money(x.owed_cents ?? 0, { cents: true })} owed{x.pending_cents ? `, ${money(x.pending_cents, { cents: true })} waiting for approval` : ''}</p>
          <ul className="stack" role="list" style={{ gap: 'var(--s-1)' }}>{x.items.map((i) => (
            <li key={i.id} className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', justifyContent: 'space-between' }}>
              <span style={{ minWidth: 0, overflowWrap: 'anywhere' }}>{i.description} <span className="small muted">{money(i.amount_cents, { cents: true })}, {i.status === 'owed' ? 'approved' : 'waiting'}</span></span>
              {i.status === 'owed' && <PaidBack id={i.id} label="Mark paid back" />}
            </li>))}</ul>
        </li>))}</ul>}
    </section>
  );
}

function Reveal({ r, what }: { r: PayIdRow; what: 'sin' | 'cheque' }) {
  const [v, setV] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const go = () => {
    const reason = window.prompt(`Why do you need ${what === 'sin' ? 'the SIN' : 'the void cheque'}? It is recorded.`, 'Payroll');
    if (!reason) return;
    start(async () => {
      const x = await payIdentityReveal({ user: r.user_id, what, reason });
      if (!x.ok) { setErr(x.message); return; }
      if (what === 'cheque') window.open(x.data.value, '_blank', 'noopener'); else setV(x.data.value);
    });
  };
  return <>{v ?? (what === 'sin' ? r.sin : '')} <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={go}>{what === 'sin' ? (v ? 'Shown' : 'Show') : 'Open'}</button>{err && <span className="error">{err}</span>}</>;
}

export function PayIdentityPanel({ rows }: { rows: PayIdRow[] }) {
  const missing = rows.filter((r) => !r.complete);
  return (
    <section className="ad-card stack" aria-labelledby="pid-h" data-testid="pay-identity-list">
      <h2 className="d4" id="pid-h">Pay details of field staff</h2>
      <p className="small">{missing.length ? `${missing.length} missing their pay details. Each has a To do.` : 'Everyone has entered their pay details.'} Showing a SIN or a cheque is recorded with your reason.</p>
      <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Table"><table className="ad-table ad-table--dense"><thead><tr><th>Person</th><th>Legal name</th><th>SIN</th><th>Void cheque</th><th>Missing</th></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.user_id}><td>{r.name}</td><td>{r.legal_name ?? ''}</td><td>{r.sin ? <Reveal r={r} what="sin" /> : ''}</td><td>{r.cheque ? <Reveal r={r} what="cheque" /> : ''}</td>
          <td>{r.missing.length ? r.missing.join(', ') : 'Complete'}</td></tr>)}</tbody></table></div>
    </section>
  );
}
