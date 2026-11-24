'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { decideEtransfer, reportEtransfer } from '@/server/actions/etransfer';
import './etransfer.css';
import { COVERS, coversWords, planWords, reportProblem, statusTone, statusWords, waitingLine, type EtransferView } from './etransfer';

// Release 49 (3610): the e-Transfer a renter sent, on the booking's Money tab (the Admin portal and the staff portals).
// Sales: "Renter sent an e-Transfer" with the amount, what it covers, the sender and the screenshot; it records nothing
// and waits for Finance. Finance and the Admins: what Confirm received would record, then one tap Confirm received (the
// payment is recorded as Record a payment does and the booking confirmed) or Not received with the reason (back to the
// rep). Every role sees the line while it waits, and the reports before it.
const fmt = (c: number) => money(Number(c ?? 0), { cents: true });

export function EtransferReports({ v, docBase }: { v: EtransferView; /** where a proof opens: /admin/documents or /staff/documents */ docBase: string }) {
  const router = useRouter();
  const ids = useId();
  const id = (k: string) => `${ids}-${k}`;
  const [pending, run] = useTransition();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ amount: '', covers: 'rental', sender: '' });
  const [file, setFile] = useState<File | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const [decline, setDecline] = useState(false);
  const [reason, setReason] = useState('');
  const [reference, setReference] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const openReport = v.reports.find((r) => r.status === 'open') ?? null;
  const past = v.reports.filter((r) => r.status !== 'open');
  if (!openReport && !v.may_report && past.length === 0) return null;
  const why = reportProblem({ amount: f.amount, covers: f.covers, file: file ? { size: file.size, type: file.type } : null, hasDeposit: v.has_deposit });

  const send = () => run(async () => {
    setMsg(null);
    const form = new FormData();
    form.set('booking', v.booking_id); form.set('booking_number', v.booking_number); form.set('amount', f.amount); form.set('covers', f.covers);
    form.set('sender_name', f.sender); if (file) form.set('proof', file);
    const r = await reportEtransfer(form);
    if (!r.ok) { setMsg({ ok: false, text: r.fieldErrors ? Object.values(r.fieldErrors).join(' ') : r.message }); return; }
    setMsg({ ok: true, text: `Sent to Finance (${r.data.report_number}). Nothing is recorded until they confirm it is in the bank; you will be told.` });
    setOpen(false); setF({ amount: '', covers: 'rental', sender: '' }); setFile(null); if (fileRef.current) fileRef.current.value = '';
    router.refresh();
  });
  const decide = (decision: 'confirm' | 'decline') => run(async () => {
    if (!openReport) return;
    setMsg(null);
    const r = await decideEtransfer({ id: openReport.id, booking_number: v.booking_number, decision, reason: decision === 'decline' ? reason : undefined, reference: decision === 'confirm' ? reference : undefined });
    if (!r.ok) { setMsg({ ok: false, text: r.fieldErrors ? Object.values(r.fieldErrors).join(' ') : r.message }); return; }
    setMsg({ ok: true, text: decision === 'confirm'
      ? `Recorded as an e-Transfer${r.data.booking_status === 'confirmed' ? ': the booking is confirmed' : ''}. ${openReport.reported_by_name ?? 'The rep'} is told.`
      : `Sent back to ${openReport.reported_by_name ?? 'the rep'} with your reason. Nothing was recorded.` });
    setDecline(false); setReason(''); setReference('');
    router.refresh();
  });

  return (
    <section className="pt-card ad-card stack et-card" aria-labelledby={id('h')} data-testid="etransfer-card">
      <div className="pt-card__head"><h2 className="d4" id={id('h')}>e-Transfer from the renter</h2>
        {openReport && <span className="ad-b ad-b--amber" data-testid="etransfer-waiting-chip">Waiting for Finance</span>}</div>

      {openReport && (
        <div className="stack et-open" data-testid="etransfer-open">
          <p className="alert alert--warn" role="status"><span>{waitingLine(openReport, fmt)}</span></p>
          <dl className="pt-dl et-dl">
            <div><dt>Amount</dt><dd><b>{fmt(openReport.amount_cents)}</b></dd></div>
            <div><dt>Covers</dt><dd>{coversWords(openReport.covers)}</dd></div>
            <div><dt>Sender</dt><dd>{openReport.sender_name ?? 'Not given'}</dd></div>
            <div><dt>Reported</dt><dd>{when(openReport.reported_at)}{openReport.reported_by_name ? `, ${openReport.reported_by_name}` : ''} ({openReport.report_number})</dd></div>
            {openReport.proof_document_id && <div><dt>Proof</dt><dd><a className="link" href={`${docBase}/${openReport.proof_document_id}`} target="_blank" rel="noreferrer" data-testid="etransfer-proof">Open the screenshot</a></dd></div>}
          </dl>
          {v.may_decide && v.plan && <p className={`small${v.plan.problem ? ' et-problem' : ''}`} id={id('plan')} data-testid="etransfer-plan">{planWords(v.plan, fmt)}</p>}
          {v.may_decide && (
            <div className="stack">
              <div className="field ad-field et-ref"><label className="label" htmlFor={id('ref')}>Bank reference (optional)</label>
                <input className="input" id={id('ref')} value={reference} onChange={(e) => setReference(e.target.value)} placeholder={openReport.report_number} autoComplete="off" data-testid="etransfer-reference" />
                <p className="hint">Empty: the report number is the reference.</p></div>
              <div className="ad-actions et-actions">
                <button className="btn btn--primary btn--sm" type="button" disabled={pending || !!v.plan?.problem} aria-busy={pending} aria-describedby={v.plan ? id('plan') : undefined} onClick={() => decide('confirm')} data-testid="etransfer-confirm">{pending && !decline ? 'Recording' : 'Confirm received'}</button>
                <button className="btn btn--ghost btn--sm" type="button" disabled={pending} aria-expanded={decline} onClick={() => setDecline(!decline)} data-testid="etransfer-decline-open">Not received</button>
              </div>
              {decline && (
                <form className="ad-form ad-form--narrow stack" aria-label="Not received" onSubmit={(e) => { e.preventDefault(); if (reason.trim().length >= 5) decide('decline'); }} data-testid="etransfer-decline-form">
                  <div className="field ad-field ad-field--wide"><label className="label" htmlFor={id('why')}>Why (the rep sees it)</label>
                    <textarea className="textarea" id={id('why')} rows={2} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Nothing from this sender in the bank yet" data-testid="etransfer-decline-reason" /></div>
                  <div className="ad-actions"><button className="btn btn--primary ad-btn--danger btn--sm" type="submit" disabled={pending || reason.trim().length < 5} aria-busy={pending} aria-describedby={id('why-d')} data-testid="etransfer-decline-go">{pending ? 'Sending back' : 'Send back to the rep'}</button></div>
                  <p className="hint" id={id('why-d')}>{reason.trim().length < 5 ? 'Say why it was not received first (5 characters or more).' : 'Nothing is recorded; the rep is told with your reason.'}</p>
                </form>)}
            </div>)}
          {!v.may_decide && v.own_report && <p className="small muted">Finance checks the bank and confirms it. You will be told either way.</p>}
          {!v.may_decide && !v.own_report && !v.may_report && v.plan === null && <p className="small muted">Finance or an Admin confirms it once it is in the bank.</p>}
        </div>)}

      {v.may_report && !openReport && (
        <>
          <p className="small muted">The renter says they sent the e-Transfer? Tell Finance here with a screenshot. Nothing is marked paid until Finance confirms it is in the bank.</p>
          <div className="ad-actions"><button className="btn btn--ghost btn--sm" type="button" aria-expanded={open} onClick={() => { setOpen(!open); setMsg(null); }} data-testid="etransfer-report-open">Renter sent an e-Transfer</button></div>
          {open && (
            <form className="ad-form ad-form--narrow stack" aria-label="Renter sent an e-Transfer" data-testid="etransfer-report-form" onSubmit={(e) => { e.preventDefault(); if (!why) send(); }}>
              <div className="ad-fields">
                <div className="field ad-field"><label className="label" htmlFor={id('amount')}>Amount sent ($)</label>
                  <input className="input" id={id('amount')} inputMode="decimal" autoComplete="off" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} data-testid="etransfer-amount" /></div>
                <div className="field ad-field"><label className="label" htmlFor={id('sender')}>Sender&apos;s name (optional)</label>
                  <input className="input" id={id('sender')} autoComplete="off" maxLength={120} value={f.sender} onChange={(e) => setF({ ...f, sender: e.target.value })} data-testid="etransfer-sender" /></div>
              </div>
              <fieldset className="stack et-covers"><legend className="label">It covers</legend>
                {COVERS.map(([c, l]) => (
                  <label key={c} className="radio"><input type="radio" name={id('covers')} value={c} checked={f.covers === c} disabled={c !== 'rental' && !v.has_deposit}
                    onChange={() => setF({ ...f, covers: c })} data-testid={`etransfer-covers-${c}`} /><span>{l}{c !== 'rental' && !v.has_deposit ? ' (no deposit on this booking)' : ''}</span></label>))}
              </fieldset>
              <div className="field ad-field ad-field--wide"><label className="label" htmlFor={id('proof')}>Screenshot or proof</label>
                <input ref={fileRef} className="input" id={id('proof')} type="file" accept="image/jpeg,image/png,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} data-testid="etransfer-proof-file" />
                <p className="hint">The renter&apos;s e-Transfer confirmation: a photo or a PDF, up to 10 MB.</p></div>
              <div className="ad-actions">
                <button className="btn btn--primary btn--sm" type="submit" disabled={pending || !!why} aria-busy={pending} aria-describedby={why ? id('why-r') : undefined} data-testid="etransfer-report-go">{pending ? 'Sending' : 'Send to Finance'}</button>
              </div>
              {why && <p className="hint" id={id('why-r')} data-testid="etransfer-report-why">{why}</p>}
            </form>)}
        </>)}

      {past.length > 0 && (
        <details className="et-past" data-testid="etransfer-history"><summary className="small">Earlier e-Transfer reports ({past.length})</summary>
          <ul className="stack et-list">{past.map((r) => (
            <li key={r.id} className="small">
              <span className={`ad-b ${statusTone(r.status)}`}>{statusWords(r.status)}</span>{' '}
              <b>{fmt(r.amount_cents)}</b> for {coversWords(r.covers)}, {r.report_number}, reported {when(r.reported_at)}{r.reported_by_name ? ` by ${r.reported_by_name}` : ''}
              {r.decided_by_name ? `; ${r.status === 'confirmed' ? 'confirmed' : 'sent back'} by ${r.decided_by_name}` : ''}{r.decline_reason ? `: ${r.decline_reason}` : ''}
              {r.proof_document_id && <> · <a className="link" href={`${docBase}/${r.proof_document_id}`} target="_blank" rel="noreferrer">Proof</a></>}
            </li>))}</ul>
        </details>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="etransfer-msg"><span>{msg.text}</span></p>}
    </section>
  );
}
