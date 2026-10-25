import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';
import { ManualPaymentForm, ManualPaymentList, type ManualRow } from '@/features/manual/ManualRecords';
import { $, Badge, Card, PageHead, Table, d, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payments, deposits, refunds', path: '/va/money', noindex: true, description: 'Finance work.' });

type R = Record<string, unknown>;
type Board = { payments_failed: R[]; deposits_due: R[]; deposits_to_take: R[]; refunds: R[]; cancellations: R[]; owner_invoices: R[]; statements: R[] };
const bk = (n: unknown) => <Link prefetch={false} className="link" href={`/va/bookings/${encodeURIComponent(String(n))}?tab=money`}>{String(n)}</Link>;

// Finance and Billing (05-va.md section 2): failed payments, deposits to take and to release, refunds to
// request (above the Single Limit they wait for an Admin), owner invoice failures, statements to prepare.
export default async function Money() {
  const { read, user, aal } = await vaPage('/va/money', ['finance']);
  const [b, open] = await Promise.all([read<Board>('finance_board'),
    door<Array<R & { id: string; invoice_number: string; balance_cents: number; manual: ManualRow[] }>>(user.id, 'ops_read', 'owner_invoices_open', {}, aal).catch(() => [])]);
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return (
    <>
      <PageHead title="Payments, deposits, refunds"><Link prefetch={false} className="btn btn--ghost btn--sm" href="/va/payments" data-testid="to-payments-by-day">Payments by day and refunds to decide</Link></PageHead>
      <div className="stack">
        <Card title="Failed payments"><Table rows={b.payments_failed} testId="failed-payments" empty="No failed payments in 30 days." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => r.booking_number ? bk(r.booking_number) : null }, { key: 'purpose', label: 'Purpose', render: (r) => label(r.purpose) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'decline_code', label: 'Decline' }, { key: 'created_at', label: 'When', render: (r) => t(r.created_at) },
          { key: 'pay', label: '', render: (r) => r.booking_number ? <ManualPaymentForm prefix="va-rp" booking={String(r.booking_number)} settlesPayment={String(r.id)} number={`${String(r.booking_number)}-${String(r.id).slice(0, 6)}`} balance={Number(r.amount_cents)} today={today} refresh={['/va/money']} label="Paid another way" /> : null }]} />
          <p className="small muted">When a renter pays a failed charge by e-Transfer, cash or another way, record it here. Amounts above your single limit need an Admin.</p></Card>
        <Card title="Owner invoices owing" testId="owner-invoices-open">{open.length ? <ul className="ow-rows">{open.map((i) => (
          <li key={i.id} data-invoice={i.invoice_number}><span><b>{i.invoice_number}</b> · {String(i.owner_name)} · {String(i.vehicle_name ?? '')}</span><span className="ow-amount">{$(i.balance_cents)}</span>
            <span className="ow-meta"><Badge s={String(i.status)} />{Number(i.paid_cents) > 0 && <span>{$(i.paid_cents)} paid so far</span>}<span>Billed {d(i.billing_date)}</span></span>
            <div style={{ flex: '1 1 100%' }}><ManualPaymentList rows={i.manual} canVoid={false} docBase="/va/documents" />
              <ManualPaymentForm prefix="va-pay" invoice={i.id} number={i.invoice_number} balance={i.balance_cents} today={today} refresh={['/va/money']} /></div></li>))}</ul>
          : <p className="small muted">No owner invoice is owing.</p>}<p className="small muted">An owner who pays by e-Transfer, cheque, cash or bank transfer: record it and the automatic debit stops (or debits only what is left). Only an Admin can void a recorded payment.</p></Card>
        <Card title="Deposits to take before pickup"><Table rows={b.deposits_to_take} empty="None in the next two days." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => bk(r.booking_number) }, { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'amount_cents', label: 'Deposit', num: true, render: (r) => $(r.amount_cents) }]} /></Card>
        <Card title="Deposits due back"><Table rows={b.deposits_due} empty="None due this week." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => bk(r.booking_number) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'method', label: 'Method', render: (r) => label(r.method) }, { key: 'release_due_on', label: 'Due', render: (r) => d(r.release_due_on) }]} /></Card>
        <Card title="Cancellations with a refund to request"><Table rows={b.cancellations} empty="Nothing to request." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => bk(r.booking_number) }, { key: 'refund_cents', label: 'Refund', num: true, render: (r) => $(r.refund_cents) }, { key: 'cancelled_at', label: 'Cancelled', render: (r) => t(r.cancelled_at) },
          { key: 'act', label: '', render: (r) => <Act action="request_refund" payload={{ booking: r.booking_id, amount_cents: r.refund_cents, reason: 'cancellation' }} label="Request the refund" refresh={['/va/money']} /> }]} /></Card>
        <Card title="Refunds in progress"><Table rows={b.refunds} testId="refunds-board" empty="No refunds in progress." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => bk(r.booking_number) }, { key: 'reason', label: 'Reason', render: (r) => label(r.reason) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => r.status === 'pending_approval' ? <Link prefetch={false} className="link" href="/va/payments">Waiting for a decision: decide it</Link> : <Badge s={String(r.status)} /> }, { key: 'due_by', label: 'Due by', render: (r) => d(r.due_by) },
          { key: 'act', label: '', render: (r) => ['approved', 'processing', 'failed'].includes(String(r.status)) ? <Act ops action="refund_issue" payload={{ id: r.id }} label={r.status === 'failed' ? 'Issue again' : 'Issue the refund'} variant="primary" testId="refund-issue" confirm={`Send ${$(r.amount_cents)} back to the card it was paid with. It is sent once, even if you press twice.`} refresh={['/va/money']} done="Refund sent." /> : null }]} /></Card>
        <Card title="Owner invoices that failed"><Table rows={b.owner_invoices} empty="No failed owner invoices." cols={[{ key: 'invoice_number', label: 'Invoice' }, { key: 'owner_name', label: 'Owner' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'balance_cents', label: 'Balance', num: true, render: (r) => $(r.balance_cents) }, { key: 'billing_date', label: 'Billed', render: (r) => d(r.billing_date) }]} /></Card>
        <Card title="Owner statements to prepare"><Table rows={b.statements} empty="No draft statements." cols={[{ key: 'owner_name', label: 'Owner' }, { key: 'month', label: 'Month', render: (r) => d(r.month) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }]} /><p className="small muted">An Admin approves statements; add notes from the statement task.</p></Card>
      </div>
    </>
  );
}
