import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import Link from 'next/link';
import { $, Badge, BookingLink, Filters, PageHead, Table, Tabs, t, d } from '@/features/admin/ui';
import { KIND_LABEL, METHOD_LABEL, PURPOSE_LABEL, cardLabel, friendly } from '@/features/money/ledger';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payments and refunds', path: '/admin/money', noindex: true, description: 'Payments, refunds, deposits, disputes.' });
type R = Record<string, unknown>;
const REFUND_REASON: Record<string, string> = { cancellation: 'Cancelled by the renter', carmacars_cancelled: 'Cancelled by CarmaCars', driver_not_verifiable: 'Driver could not be verified',
  pricing_error: 'Pricing error', breakdown_unused_days: 'Breakdown: days not used', goodwill: 'Goodwill', duplicate: 'Charged twice', other: 'Other' };

// Money (03-admin.md section 11): payments, refunds with approval limits, deposits, disputes.
export default async function Money({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/money'), searchParams]);
  const tab = sp.tab ?? 'payments';
  const cur = `/admin/money?tab=${tab}`;
  const tabs = <Tabs current={cur} items={[['/admin/money?tab=payments', 'Payments'], ['/admin/money?tab=refunds', 'Refunds'], ['/admin/money?tab=deposits', 'Deposits'], ['/admin/money?tab=disputes', 'Disputes']]} />;
  if (tab === 'refunds') {
    const { rows } = await list('refunds', { eq: sp.status ? { status: sp.status } : {}, limit: 200 });
    return (<><PageHead title="Refunds" />{tabs}
      <Filters base="/admin/money" name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['pending_approval', 'Waiting for approval'], ['approved', 'Approved'], ['paid', 'Paid'], ['rejected', 'Rejected'], ['failed', 'Failed']]} />
      <p className="small muted">Approving is checked against your approval limit and the second-approver rule; the payments module then issues the refund. <Link prefetch={false} className="link" href="/admin/payments">Payments by day</Link> lists the refunds waiting with the policy maths, decided in the same row.</p>
      <Table<R> testId="refunds" rows={rows} empty="No refunds waiting for approval." cols={[{ key: 'created_at', label: 'Requested', render: (r) => t(r.created_at) }, { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'reason', label: 'Reason', render: (r) => friendly(REFUND_REASON, r.reason) },
        { key: 'refund_bps', label: '%', num: true, render: (r) => r.refund_bps !== null ? `${Number(r.refund_bps) / 100}%` : '' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
        { key: 'due_by', label: 'Due by', render: (r) => d(r.due_by) }, { key: 'paid_at', label: 'Paid', render: (r) => t(r.paid_at) }, { key: 'note', label: 'Note', className: 'wrap' },
        { key: 'act', label: 'Decide', render: (r) => r.status === 'pending_approval' ? <span className="ad-actions"><Act action="refund_approve" payload={{ id: r.id }} label="Approve" variant="primary" refresh={['/admin/money']} /><Act action="refund_reject" payload={{ id: r.id }} label="Reject" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={['/admin/money']} /></span>
          : ['approved', 'processing', 'failed'].includes(String(r.status)) ? <Act ops action="refund_issue" payload={{ id: r.id }} label={r.status === 'failed' ? 'Issue again' : 'Issue the refund'} variant="primary" testId="refund-issue"
              confirm={`Send ${$(r.amount_cents)} back to the card it was paid with. It is sent once, even if you press twice.`} refresh={['/admin/money']} done="Refund sent." /> : null }]} /></>);
  }
  if (tab === 'deposits') {
    const { rows } = await list('deposits', { limit: 200 });
    return (<><PageHead title="Deposits" />{tabs}
      <Table<R> testId="deposits" rows={rows} empty="No deposits held or due." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'method', label: 'Method', render: (r) => friendly(METHOD_LABEL, r.paid_method ?? r.method) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
        { key: 'hold_expires_at', label: 'Hold expires', render: (r) => t(r.hold_expires_at) }, { key: 'applied_cents', label: 'Applied', num: true, render: (r) => $(r.applied_cents) }, { key: 'held_back_cents', label: 'Held back', num: true, render: (r) => $(r.held_back_cents) }, { key: 'held_back_until', label: 'Until', render: (r) => d(r.held_back_until) },
        { key: 'release_due_on', label: 'Release due', render: (r) => d(r.release_due_on) }, { key: 'released_cents', label: 'Released', num: true, render: (r) => $(r.released_cents) }]} /></>);
  }
  if (tab === 'disputes') {
    const { rows } = await list('disputes', { limit: 200 });
    return (<><PageHead title="Disputes" />{tabs}
      <Table<R> testId="disputes" rows={rows} empty="No disputes. A chargeback the bank opens shows up here with its deadline." cols={[{ key: 'opened_at', label: 'Opened', render: (r) => t(r.opened_at) }, { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'reason', label: 'Reason' },
        { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'evidence_due_at', label: 'Evidence due', render: (r) => t(r.evidence_due_at) }, { key: 'owner_revenue_withheld_cents', label: 'Owner Revenue withheld', num: true, render: (r) => $(r.owner_revenue_withheld_cents) },
        { key: 'act', label: '', render: (r) => r.evidence_submitted_at ? `submitted ${t(r.evidence_submitted_at)}` : <Act action="dispute_submitted" payload={{ id: r.id }} label="Mark evidence submitted" refresh={['/admin/money']} /> }]} /></>);
  }
  const { rows, count } = await list('payments', { eq: { ...(sp.status ? { status: sp.status } : {}), ...(sp.purpose ? { purpose: sp.purpose } : {}) }, limit: 200 });
  return (<><PageHead title="Payments" kicker={`${count} payments`}><Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/payments" data-testid="to-payments-by-day">Payments by day, with totals and the cash drawer</Link></PageHead>{tabs}
    <Filters base="/admin/money" name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['succeeded', 'Succeeded'], ['pending', 'Pending'], ['authorized', 'Authorized'], ['failed', 'Failed'], ['cancelled', 'Cancelled']]} />
    <Table<R> testId="payments" rows={rows} empty="No payments." cols={[{ key: 'created_at', label: 'Date', render: (r) => t(r.created_at) }, { key: 'who', label: 'Booking or owner', render: (r) => r.booking_number ? <BookingLink n={r.booking_number} /> : String(r.owner_name ?? '') },
      { key: 'purpose', label: 'For', render: (r) => friendly(PURPOSE_LABEL, r.purpose) }, { key: 'kind', label: 'Kind', render: (r) => friendly(KIND_LABEL, r.kind) }, { key: 'method', label: 'Method', render: (r) => friendly(METHOD_LABEL, r.method) },
      { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
      { key: 'card_last4', label: 'Card', render: (r) => cardLabel(r.card_brand, r.card_last4) }, { key: 'decline_count', label: 'Declines', num: true }, { key: 'next_retry_at', label: 'Next retry', render: (r) => t(r.next_retry_at) }, { key: 'dispute_status', label: 'Dispute' }]} /></>);
}
