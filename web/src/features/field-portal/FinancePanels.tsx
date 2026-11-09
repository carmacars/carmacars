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
const STATUS: Record<string, string> = { submitted: 'Waiting', approved: 'Approved', refused: 'Refused', reimbursed: 'Paid back' };

function SpendActions({ r }: { r: SpendRow }) {
  const router = useRouter();
  const [note, setNote] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const go = (action: 'field_spend_decide' | 'field_spend_paid_back', approve?: boolean) => start(async () => {
    setErr(null);
    const x = await spendDo(action, { id: r.id, approve, note });
    if (!x.ok) { setErr(x.message); return; }
    router.refresh();
  });
  return (
    <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-1)' }}>
      {r.status === 'submitted' && <>
        <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={() => go('field_spend_decide', true)} data-testid={`spend-approve-${r.id}`}>Approve</button>
        <input className="input" style={{ maxWidth: '12rem' }} placeholder="Why refused" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Why refused" />
        <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => go('field_spend_decide', false)}>Refuse</button></>}
      {r.status === 'approved' && r.paid_with === 'own' && <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={() => go('field_spend_paid_back')} data-testid={`spend-paid-${r.id}`}>Mark paid back</button>}
      {err && <span className="error" role="alert">{err}</span>}
    </div>
  );
}

export function SpendingPanel({ rows }: { rows: SpendRow[] }) {
  return (
    <section className="ad-card stack" aria-labelledby="fs-h" data-testid="field-spending">
      <h2 className="d4" id="fs-h">Field spending to approve or pay back</h2>
      {rows.length === 0 ? <p className="small muted">Nothing waiting.</p> : <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Table"><table className="ad-table ad-table--dense"><thead><tr><th>Who</th><th>What</th><th>Amount</th><th>Receipt</th><th>Status</th><th /></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.id}><td>{r.staff}<br /><span className="small muted">{r.spent_on}</span></td>
          <td>{r.description}{r.vehicle ? <><br /><span className="small muted">{r.vehicle}{r.booking ? `, ${r.booking}` : ''}</span></> : null}{r.service ? <><br /><span className="small">Service: already on the car</span></> : null}</td>
          <td>{money(r.amount_cents + r.hst_cents, { cents: true })}<br /><span className="small muted">{r.paid_with === 'own' ? 'Their own money' : 'Company paid'}</span></td>
          <td>{r.receipt_url ? <a className="link" href={r.receipt_url} target="_blank" rel="noreferrer">Open</a> : <span className="small">Missing</span>}</td>
          <td>{STATUS[r.status] ?? r.status}{r.note ? <><br /><span className="small muted">{r.note}</span></> : null}</td><td><SpendActions r={r} /></td></tr>)}</tbody></table></div>}
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
