'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { creditNote, issueInvoice, resendInvoice, voidInvoice } from '@/server/actions/owner-billing';
import { toCents } from './shared';

// What an Admin does with one owner invoice (migration 0067): issue a draft, void with a reason (and make the corrected
// one), a credit note for a paid one, send the email again. Record payment is the form of 0044, next to these.
export function InvoiceActions({ id, number, can, paths = [] }: { id: string; number: string; can: { issue: boolean; void: boolean; credit: boolean; resend: boolean }; paths?: string[] }) {
  const router = useRouter();
  const a = useAct<Record<string, unknown>>();
  const uid = `ia-${useId().replace(/[^\w-]/g, '')}`;
  const [mode, setMode] = useState<'' | 'void' | 'credit'>('');
  const [reason, setReason] = useState('');
  const [reissue, setReissue] = useState(true);
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState<string | null>(null);
  const all = [...paths, `/admin/invoices/${number}`];
  return (
    <div className="stack" data-testid="invoice-actions">
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        {can.issue && <button type="button" className="btn btn--primary btn--sm" disabled={a.pending} data-testid="invoice-issue"
          onClick={() => { if (window.confirm(`Issue ${number}? The owner is emailed and it cannot be edited after.`)) a.run(() => issueInvoice(id, all), (r) => { if (r.ok) { setNote('Issued. The owner was emailed.'); router.refresh(); } }); }}>Issue and email</button>}
        {can.resend && <button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} data-testid="invoice-resend"
          onClick={() => a.run(() => resendInvoice(id, all), (r) => { if (r.ok) { setNote('The invoice email was sent again.'); router.refresh(); } })}>Resend email</button>}
        {can.void && <button type="button" className="btn btn--ghost btn--sm" aria-expanded={mode === 'void'} onClick={() => setMode(mode === 'void' ? '' : 'void')} data-testid="invoice-void-open">Void</button>}
        {can.credit && <button type="button" className="btn btn--ghost btn--sm" aria-expanded={mode === 'credit'} onClick={() => setMode(mode === 'credit' ? '' : 'credit')} data-testid="invoice-credit-open">Credit note</button>}
        <a className="btn btn--quiet btn--sm" href={`/files/owner_invoice/${id}`} target="_blank" rel="noreferrer" data-testid="invoice-pdf">PDF</a>
      </div>
      {mode === 'void' && (
        <form className="stack pt-sheet" noValidate aria-label={`Void ${number}`} onSubmit={(e) => { e.preventDefault(); a.run(() => voidInvoice(id, reason, reissue, all), (r) => {
          if (!r.ok) return; setMode('');
          const n = (r.data as { replacement_number?: string | null }).replacement_number;
          if (n) router.push(`/admin/invoices/${n}?replaces=${number}`); else { setNote('Voided.'); router.refresh(); }
        }); }}>
          <div className={`field${a.err('reason') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-r`}>Reason (the owner reads it)</label>
            <textarea className="input" id={`${uid}-r`} rows={2} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="invoice-void-reason" aria-describedby={`${uid}-r-e`} />
            <p className="error" role="alert" id={`${uid}-r-e`}>{a.err('reason') ?? ''}</p></div>
          <label className="check" htmlFor={`${uid}-re`}><input type="checkbox" id={`${uid}-re`} checked={reissue} onChange={(e) => setReissue(e.target.checked)} data-testid="invoice-void-reissue" /><span>Make a corrected invoice from it (a draft to edit, then issue)</span></label>
          <p className="small muted">An issued invoice is never changed: it is voided, its scheduled debit is cancelled, and the owner is told. Nothing paid can be on it.</p>
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending} data-testid="invoice-void-send">{a.pending ? 'Voiding' : 'Void the invoice'}</button></div>
        </form>)}
      {mode === 'credit' && (
        <form className="stack pt-sheet" noValidate aria-label={`Credit note for ${number}`} onSubmit={(e) => { e.preventDefault(); a.run(() => creditNote(id, toCents(amount), reason, all), (r) => { if (r.ok) { setMode(''); router.push(`/admin/invoices/${(r.data as { invoice_number: string }).invoice_number}`); } }); }}>
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
