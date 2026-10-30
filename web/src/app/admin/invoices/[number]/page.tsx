import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Badge, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';
import { InvoiceEditor, type DraftLine } from '@/features/owner-billing/InvoiceEditor';
import { InvoiceActions } from '@/features/owner-billing/InvoiceActions';
import { invoiceWhat, type InvoiceRow } from '@/features/owner-billing/InvoiceList';
import { INVOICE_BADGE, statusText } from '@/features/owner-billing/shared';
import { ManualPaymentForm, ManualPaymentList, type ManualRow } from '@/features/manual/ManualRecords';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner invoice', path: '/admin/invoices', noindex: true, description: 'One owner invoice.' });

type Line = DraftLine & { id: string; amount_cents: number; hst_cents: number };
interface Detail extends InvoiceRow {
  notes: string | null; fees_cents: number; hst_cents: number; late_fee_cents: number; deducted_cents: number; voided_at: string | null; voided_by: string | null;
  email_count: number; last_emailed_at: string | null; owner_email: string | null; lines: Line[];
  payments: Array<{ id: string; method_label: string; status: string; amount_cents: number; created_at: string; processed_at: string | null; card_last4: string | null; receipt: boolean }>;
  manual: ManualRow[]; debits: Array<{ attempt_no: number; debit_on: string; amount_cents: number; status: string; skip_reason: string | null; failure_message: string | null }>;
  debit: Record<string, unknown> | null; emails: Array<{ code: string; at: string; processed: boolean }>; history: Array<{ action: string; at: string; by: string | null }>;
  credit_notes: Array<{ invoice_number: string; total_cents: number }>; can: { edit: boolean; issue: boolean; void: boolean; credit: boolean; record_payment: boolean; resend: boolean };
}
const EMAIL: Record<string, string> = { owner_upfront_invoice: 'Invoice email', owner_fee_invoice: 'Invoice email', owner_invoice_issued: 'Invoice email', owner_invoice_voided: 'Void notice',
  owner_payment_received: 'Payment received', owner_payment_failed: 'Payment failed', owner_in_arrears: 'In arrears', owner_debit_notice: 'Debit notice' };
const ACTION: Record<string, string> = { owner_invoice_draft_create: 'Draft made', owner_invoice_draft_edit: 'Draft edited', owner_invoice_issue: 'Issued', owner_invoice_void: 'Voided',
  owner_invoice_resend: 'Email sent again', owner_invoice_credit_note: 'Credit note issued', record_manual_payment: 'Payment recorded by hand', void_manual_payment: 'Payment voided' };

// One owner invoice (migration 0067): the lines, the totals, payments, receipts, debits, the emails sent and the
// history; a draft is edited here; an issued one is issued, voided and reissued, credited, resent, paid by hand.
export default async function AdminInvoice({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ number }, sp] = await Promise.all([params, searchParams]);
  if (!/^INV-\d+$/i.test(number)) notFound();
  const { user } = await page(`/admin/invoices/${number}`);
  const i = await door<Detail>(user.id, 'ops_read', 'owner_invoice_admin', { id: number.toUpperCase() }).catch(() => null);
  if (!i) notFound();
  const facts = await door<{ hst_bps: number }>(user.id, 'ops_read', 'owner_add_car_facts', {});
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const paths = [`/admin/owners/${i.owner_id}`, '/admin/invoices'];
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/invoices">Owner invoices</Link> · <Link prefetch={false} className="link" href={`/admin/owners/${i.owner_id}?tab=invoices`}>{i.owner_name}</Link></>}
        title={`${i.invoice_number}: ${invoiceWhat(i)}`}>
        <Badge s={i.partly_paid ? 'sent' : INVOICE_BADGE[i.status] ?? i.status}>{statusText(i.status, i.partly_paid, i.from_statement)}</Badge>
      </PageHead>
      {sp.replaces && <p className="alert alert--ok" role="status" data-testid="invoice-replacement-note"><span>{sp.replaces} is void. This is the corrected invoice, a draft: check the lines, then issue it.</span></p>}
      {sp.issued && <p className="alert alert--ok" role="status"><span>Issued. The owner was emailed.</span></p>}
      {i.status === 'void' && <p className="alert alert--warn" role="status" data-testid="invoice-void-note"><span>Void{i.voided_at ? ` since ${t(i.voided_at)}` : ''}{i.voided_by ? ` (${i.voided_by})` : ''}: {i.void_reason}{i.replaced_by ? `. Replaced by ${i.replaced_by}.` : ''}</span></p>}
      <div className="ad-cols ad-cols--main">
        <div className="stack">
          {i.can.edit ? (
            <Card title="Draft: edit the lines" testId="invoice-draft">
              <p className="small muted">The owner sees nothing until it is issued. A draft is never debited.</p>
              <InvoiceEditor draft={{ id: i.id, vehicle_id: i.vehicle_id, kind: i.kind, title: i.title, notes: i.notes, due_on: i.due_on, lines: i.lines }} cars={[]} hstBps={facts.hst_bps} paths={paths} stay />
            </Card>
          ) : (
            <Card title="Lines" testId="invoice-lines-view">
              <Table rows={i.lines as unknown as Array<Record<string, unknown>>} caption="Invoice lines" cols={[
                { key: 'description', label: 'Description', className: 'wrap', render: (l) => <>{String(l.description)}{l.note ? <><br /><span className="small muted">{String(l.note)}</span></> : null}</> },
                { key: 'quantity', label: 'Qty', num: true, render: (l) => String(Number(l.quantity)) },
                { key: 'unit_amount_cents', label: 'Unit', num: true, render: (l) => money(Number(l.unit_amount_cents), { cents: true }) },
                { key: 'amount_cents', label: 'Amount', num: true, render: (l) => money(Number(l.amount_cents), { cents: true }) },
                { key: 'hst_cents', label: 'HST', num: true, render: (l) => (l.hst ? money(Number(l.hst_cents), { cents: true }) : 'No HST') }]} />
              <Kv rows={[['Before HST', money(i.fees_cents, { cents: true })], ['HST', money(i.hst_cents, { cents: true })], ...(i.late_fee_cents ? [['Late Fee', money(i.late_fee_cents, { cents: true })] as [string, string]] : []),
                ['Total', <b key="t" data-testid="invoice-detail-total">{money(i.total_cents, { cents: true })}</b>], ['Paid', money(i.paid_cents, { cents: true })], ...(i.deducted_cents ? [['Deducted from payout', money(i.deducted_cents, { cents: true })] as [string, string]] : []),
                ['Owing', money(Math.max(0, i.balance_cents), { cents: true })]]} />
              {i.notes && <p className="small"><b>Notes:</b> {i.notes}</p>}
            </Card>)}
          <Card title="Payments and receipts" testId="invoice-payments">
            {i.payments.length ? <ul className="ad-list">{i.payments.map((p) => <li key={p.id}><span>{money(p.amount_cents, { cents: true })} by {p.method_label}{p.card_last4 ? ` ending ${p.card_last4}` : ''} · {p.status}</span>
              <span className="small">{t(p.processed_at ?? p.created_at)}{p.receipt ? <> · <a className="link" href={`/files/receipt/${p.id}`} target="_blank" rel="noreferrer">Receipt</a></> : null}</span></li>)}</ul>
              : <p className="small muted">No payment yet.</p>}
            <ManualPaymentList rows={i.manual} canVoid refresh={[`/admin/invoices/${i.invoice_number}`, ...paths]} />
            {i.can.record_payment && <ManualPaymentForm invoice={i.id} number={i.invoice_number} balance={i.balance_cents} today={today} refresh={[`/admin/invoices/${i.invoice_number}`, ...paths]} />}
          </Card>
          <Card title="Automatic debits" testId="invoice-debits">
            {i.debits.length ? <ul className="ad-list">{i.debits.map((x) => <li key={x.attempt_no}><span>Debit {x.attempt_no}: {money(x.amount_cents, { cents: true })} on {d(x.debit_on)}</span><span className="small">{x.status}{x.skip_reason ? `: ${x.skip_reason}` : ''}{x.failure_message ? `: ${x.failure_message}` : ''}</span></li>)}</ul>
              : <p className="small muted">{i.status === 'draft' ? 'A draft is never debited.' : 'No debit scheduled for this invoice.'}</p>}
          </Card>
        </div>
        <div className="stack">
          <Card title="Invoice" testId="invoice-facts">
            <Kv rows={[['Owner', <Link key="o" prefetch={false} className="link" href={`/admin/owners/${i.owner_id}?tab=invoices`}>{i.owner_name}</Link>], ['Email', i.owner_email], ['Car', i.vehicle_name],
              ['Application', i.application_number], ['Issued', i.issued_at ? t(i.issued_at) : 'Not yet'], ['Due', i.due_on ? d(i.due_on) : ''], ['Replaces', i.replaces], ['Replaced by', i.replaced_by], ['Credit for', i.credit_for],
              ['Credit notes', i.credit_notes.map((c) => `${c.invoice_number} (${money(c.total_cents, { cents: true })})`).join(', ')]]} />
          </Card>
          <Card title="Actions"><InvoiceActions id={i.id} number={i.invoice_number} can={i.can} paths={paths} /></Card>
          <Card title="Emails" testId="invoice-emails">
            {i.emails.length ? <ul className="ad-list">{i.emails.map((e, k) => <li key={k}><span>{EMAIL[e.code] ?? e.code.replace(/_/g, ' ')}</span><span className="small">{t(e.at)}{e.processed ? '' : ' · waiting'}</span></li>)}</ul> : <p className="small muted">No email yet.</p>}
          </Card>
          <Card title="History">
            {i.history.length ? <ul className="ad-list">{i.history.map((h, k) => <li key={k}><span>{ACTION[h.action] ?? h.action.replace(/_/g, ' ')}</span><span className="small">{t(h.at)}{h.by ? ` · ${h.by}` : ''}</span></li>)}</ul> : <p className="small muted">Nothing yet.</p>}
          </Card>
        </div>
      </div>
    </>
  );
}
