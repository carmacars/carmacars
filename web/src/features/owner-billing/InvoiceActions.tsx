'use client';
import { useId, useState } from 'react';
import { scrollOption } from '@/lib/nav/same-page';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { creditNote, issueInvoice, payInvoiceOutside, resendInvoice, voidInvoice } from '@/server/actions/owner-billing';
import { DateInput } from '@/components/DateInput';
import { OUTSIDE_METHODS } from './paid-outside';
import { toCents } from './shared';

// What an Admin does with one owner invoice (migration 0067): issue a draft, void with a reason (and make the corrected
// one), a credit note for a paid one, send the email again. Record payment is the form of 0044, next to these.
export function InvoiceActions({ id, number, status = 'issued', can, paths = [] }: { id: string; number: string; status?: string; can: { issue: boolean; void: boolean; credit: boolean; resend: boolean; record_payment?: boolean }; paths?: string[] }) {
  const router = useRouter();
  const a = useAct<Record<string, unknown>>();
  const uid = `ia-${useId().replace(/[^\w-]/g, '')}`;
  const [mode, setMode] = useState<'' | 'void' | 'credit' | 'paid'>('');
  const [reason, setReason] = useState('');
  const [reissue, setReissue] = useState(true);
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState<string | null>(null);
  const [pay, setPay] = useState({ method: 'e_transfer', received_on: new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()), reference: '', note: '', amount: '', receipt: false });
  const all = [...paths, `/admin/invoices/${number}`];
  return (
    <div className="stack" data-testid="invoice-actions">
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        {can.issue && <button type="button" className="btn btn--primary btn--sm" disabled={a.pending} data-testid="invoice-issue"
          onClick={() => { if (window.confirm(`Issue ${number}? The owner is emailed and it cannot be edited after.`)) a.run(() => issueInvoice(id, all), (r) => { if (r.ok) { setNote('Issued. The owner was emailed.'); router.refresh(); } }); }}>Issue and email</button>}
        {can.issue && <button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} data-testid="invoice-issue-quiet"
          onClick={() => { if (window.confirm(`Issue ${number} without emailing the owner? Use it for a bill already paid outside the platform, then record the payment below. It cannot be edited after.`)) a.run(() => issueInvoice(id, all, false), (r) => { if (r.ok) { setNote('Issued without an email.'); router.refresh(); } }); }}>Issue without email</button>}
        {(can.issue || can.record_payment) && <button type="button" className="btn btn--ghost btn--sm" aria-expanded={mode === 'paid'} onClick={() => setMode(mode === 'paid' ? '' : 'paid')} data-testid="invoice-paid-outside-open">Already paid outside the platform</button>}
        {can.resend && <button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} data-testid="invoice-resend"
          onClick={() => a.run(() => resendInvoice(id, all), (r) => { if (r.ok) { setNote('The invoice email was sent again.'); router.refresh(); } })}>Resend email</button>}
        {can.void && <button type="button" className="btn btn--ghost btn--sm" aria-expanded={mode === 'void'} onClick={() => setMode(mode === 'void' ? '' : 'void')} data-testid="invoice-void-open">Void</button>}
        {can.credit && <button type="button" className="btn btn--ghost btn--sm" aria-expanded={mode === 'credit'} onClick={() => setMode(mode === 'credit' ? '' : 'credit')} data-testid="invoice-credit-open">Credit note</button>}
        <a className="btn btn--quiet btn--sm" href={`/files/owner_invoice/${id}`} target="_blank" rel="noreferrer" data-testid="invoice-pdf">PDF</a>
      </div>
      {mode === 'paid' && (
        <form className="stack pt-sheet" noValidate aria-label={`${number} already paid outside the platform`} data-testid="invoice-paid-outside"
          onSubmit={(e) => { e.preventDefault(); a.run(() => payInvoiceOutside(id, pay, status, all), (r) => { if (r.ok) { setMode(''); setNote(status === 'draft' ? 'Issued without an email and recorded as paid.' : 'Recorded as paid.'); router.refresh(); } }); }}>
          <p className="small muted">{status === 'draft' ? 'The invoice is issued without an email, then the payment is recorded. ' : ''}The owner gets no invoice email{pay.receipt ? '' : ' and no receipt'}.</p>
          <div className="field-row">
            <div className={`field${a.err('method') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-pm`}>Paid by</label>
              <select className="select" id={`${uid}-pm`} value={pay.method} onChange={(e) => setPay({ ...pay, method: e.target.value })} data-testid="invoice-paid-method">{OUTSIDE_METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
              <p className="error" role="alert">{a.err('method') ?? ''}</p></div>
            <div className={`field${a.err('received_on') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-pd`}>Date paid</label>
              <DateInput className="input" id={`${uid}-pd`} type="date" value={pay.received_on} onChange={(e) => setPay({ ...pay, received_on: e.target.value })} data-testid="invoice-paid-date" />
              <p className="error" role="alert">{a.err('received_on') ?? ''}</p></div>
          </div>
          <div className="field-row">
            <div className={`field${a.err('reference') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-pr`}>{pay.method === 'cheque' ? 'Cheque number' : 'Reference'}</label>
              <input className="input" id={`${uid}-pr`} value={pay.reference} onChange={(e) => setPay({ ...pay, reference: e.target.value })} data-testid="invoice-paid-ref" />
              <p className="error" role="alert">{a.err('reference') ?? ''}</p></div>
            <div className={`field${a.err('amount') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-pa`}>Amount ($)</label>
              <input className="input" id={`${uid}-pa`} inputMode="decimal" value={pay.amount} onChange={(e) => setPay({ ...pay, amount: e.target.value })} placeholder="Empty: the full balance" />
              <p className="error" role="alert">{a.err('amount') ?? ''}</p></div>
          </div>
          <div className="field"><label className="label" htmlFor={`${uid}-pn`}>Note (optional)</label>
            <input className="input" id={`${uid}-pn`} value={pay.note} onChange={(e) => setPay({ ...pay, note: e.target.value })} /></div>
          <label className="check" htmlFor={`${uid}-rc`}><input type="checkbox" id={`${uid}-rc`} checked={pay.receipt} onChange={(e) => setPay({ ...pay, receipt: e.target.checked })} data-testid="invoice-paid-receipt" /><span>Email the owner a receipt</span></label>
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending} data-testid="invoice-paid-go">{a.pending ? 'Recording' : status === 'draft' ? 'Issue quietly and record as paid' : 'Record as paid'}</button></div>
        </form>)}
      {mode === 'void' && (
        <form className="stack pt-sheet" noValidate aria-label={`Void ${number}`} onSubmit={(e) => { e.preventDefault(); a.run(() => voidInvoice(id, reason, reissue, all), (r) => {
          if (!r.ok) return; setMode('');
          const n = (r.data as { replacement_number?: string | null }).replacement_number;
          if (n) router.push(`/admin/invoices/${n}?replaces=${number}`, scrollOption(`/admin/invoices/${n}?replaces=${number}`)); else { setNote('Voided.'); router.refresh(); }
        }); }}>
          <div className={`field${a.err('reason') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-r`}>Reason (the owner reads it)</label>
            <textarea className="input" id={`${uid}-r`} rows={2} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="invoice-void-reason" aria-describedby={`${uid}-r-e`} />
            <p className="error" role="alert" id={`${uid}-r-e`}>{a.err('reason') ?? ''}</p></div>
          <label className="check" htmlFor={`${uid}-re`}><input type="checkbox" id={`${uid}-re`} checked={reissue} onChange={(e) => setReissue(e.target.checked)} data-testid="invoice-void-reissue" /><span>Make a corrected invoice from it (a draft to edit, then issue)</span></label>
          <p className="small muted">An issued invoice is never changed: it is voided, its scheduled debit is cancelled, and the owner is told. Nothing paid can be on it.</p>
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending} data-testid="invoice-void-send">{a.pending ? 'Voiding' : 'Void the invoice'}</button></div>
        </form>)}
      {mode === 'credit' && (
        <form className="stack pt-sheet" noValidate aria-label={`Credit note for ${number}`} onSubmit={(e) => { e.preventDefault(); a.run(() => creditNote(id, toCents(amount), reason, all), (r) => { if (r.ok) { setMode(''); router.push(`/admin/invoices/${(r.data as { invoice_number: string }).invoice_number}`, scrollOption(`/admin/invoices/${(r.data as { invoice_number: string }).invoice_number}`)); } }); }}>
          <div className="field-row">
            <div className={`field${a.err('amount') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-a`}>Amount to credit, before HST ($)</label>
              <input className="input" id={`${uid}-a`} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} aria-describedby={`${uid}-a-e`} />
              <p className="error" role="alert" id={`${uid}-a-e`}>{a.err('amount') ?? ''}</p></div>
            <div className={`field${a.err('reason') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-cr`}>Reason (the owner reads it)</label>
              <input className="input" id={`${uid}-cr`} value={reason} onChange={(e) => setReason(e.target.value)} aria-describedby={`${uid}-cr-e`} />
              <p className="error" role="alert" id={`${uid}-cr-e`}>{a.err('reason') ?? ''}</p></div>
          </div>
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending}>Issue the credit note</button></div>
        </form>)}
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {note && <p className="alert alert--ok" role="status" data-testid="invoice-action-done"><span>{note}</span></p>}
    </div>
  );
}
