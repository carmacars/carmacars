import Link from 'next/link';
import { money } from '@/lib/format';
import { Badge, d } from '@/features/admin/ui';
import { INVOICE_BADGE, KIND_LABEL, statusText } from './shared';

// Every owner invoice of an owner, an application or everyone (migration 0067): drafts, issued, partly paid, paid,
// void, each opening its own page.
export interface InvoiceRow { id: string; invoice_number: string; owner_id: string; owner_name: string; vehicle_id: string; vehicle_name: string; kind: string; kind_label: string; title: string | null;
  period_month: string | null; status: string; total_cents: number; balance_cents: number; paid_cents: number; billing_date: string; issued_at: string | null; due_on: string | null;
  created_at: string; void_reason: string | null; replaces: string | null; replaced_by: string | null; credit_for: string | null; partly_paid: boolean; application_number: string | null; from_statement?: boolean }
export interface InvoiceListData { rows: InvoiceRow[]; counts: { draft: number; open: number; paid: number; void: number }; cars: Array<{ id: string; name: string; owner_id: string }> }

const month = (iso: string | null) => (iso ? new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', month: 'long', year: 'numeric' }) : '');
export const invoiceWhat = (i: Pick<InvoiceRow, 'title' | 'kind' | 'period_month'>) => i.title ?? (i.kind === 'monthly' ? `Monthly fees, ${month(i.period_month)}` : KIND_LABEL[i.kind] ?? i.kind);

export function InvoiceList({ data, owner = true, newHref, testId = 'invoice-list' }: { data: InvoiceListData; owner?: boolean; newHref?: string; testId?: string }) {
  return (
    <div className="stack">
      <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <p className="small muted">{data.counts.draft} draft · {data.counts.open} open · {data.counts.paid} paid · {data.counts.void} void</p>
        {newHref && <Link prefetch={false} className="btn btn--primary btn--sm" href={newHref} data-testid="invoice-new">New invoice</Link>}
      </div>
      {data.rows.length ? (
        <ul className="ow-rows" data-testid={testId}>{data.rows.map((i) => (
          <li key={i.id} data-invoice={i.invoice_number} data-status={i.status}>
            <Link prefetch={false} className="ow-row-link" href={`/admin/invoices/${i.invoice_number}`}><b>{i.invoice_number}</b> · {invoiceWhat(i)}</Link>
            <span className="ow-amount">{money(i.total_cents, { cents: true })}</span>
            <span className="ow-meta">
              <Badge s={i.partly_paid ? 'sent' : INVOICE_BADGE[i.status] ?? i.status}>{statusText(i.status, i.partly_paid, i.from_statement)}</Badge>
              <span>{i.vehicle_name}</span>{owner && <span>{i.owner_name}</span>}
              <span>{i.status === 'draft' ? `Made ${d(i.created_at)}` : `Issued ${d(i.issued_at ?? i.billing_date)}`}</span>
              {i.due_on && !['paid', 'void', 'draft'].includes(i.status) && <span>Due {d(i.due_on)}</span>}
              {i.balance_cents > 0 && !['paid', 'void', 'draft'].includes(i.status) && <span>{money(i.balance_cents, { cents: true })} owing</span>}
              {i.status === 'void' && i.void_reason && <span>Void: {i.void_reason}</span>}
              {i.replaced_by && <span>Replaced by {i.replaced_by}</span>}{i.replaces && <span>Replaces {i.replaces}</span>}{i.credit_for && <span>Credit for {i.credit_for}</span>}
            </span>
          </li>))}
        </ul>) : <p className="pt-empty muted">No invoices yet.</p>}
    </div>
  );
}
