import Link from '@/components/Link';
import type { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { $, Badge, Filters, PageHead, Table, d, t } from '@/features/admin/ui';
import { KIND_LABEL, METHOD_LABEL, PURPOSE_LABEL, cardLabel, friendly } from '@/features/money/ledger';

type Ctx = Awaited<ReturnType<typeof vaPage>>;
type R = Record<string, unknown>;
const bk = (n: unknown) => (n ? <Link prefetch={false} className="link" href={`/staff/bookings/${encodeURIComponent(String(n))}?tab=money`}>{String(n)}</Link> : null);
const REFUND_REASON: Record<string, string> = { cancellation: 'Cancelled by the renter', carmacars_cancelled: 'Cancelled by CarmaCars', driver_not_verifiable: 'Driver could not be verified',
  pricing_error: 'Pricing error', breakdown_unused_days: 'Breakdown: days not used', goodwill: 'Goodwill', duplicate: 'Charged twice', other: 'Other' };

// Finance > Money's lists (r27 consolidation: Admin's All payments, Refunds and Deposits tabs for the finance role). The
// rows come through va_list, which lets finance list these tables (migration 0031); deciding a refund stays on By day,
// within the finance member's limit, as before.

export async function Payments({ ctx, status }: { ctx: Ctx; status?: string }) {
  const { rows, count } = await ctx.list<R>('payments', { eq: status ? { status } : {}, limit: 200 });
  return (<>
    <PageHead title="All payments" kicker={`${count} payments`} purpose="Every payment, newest first. By day has the totals by method and the cash drawer." />
    <Filters base="/staff/money?tab=payments" name="status" value={status ?? ''} sp={{ tab: 'payments', ...(status ? { status } : {}) }} options={[['', 'All'], ['succeeded', 'Succeeded'], ['pending', 'Pending'], ['authorized', 'Authorized'], ['failed', 'Failed'], ['cancelled', 'Cancelled']]} />
    <Table<R> testId="payments" rows={rows} empty="No payments." cols={[{ key: 'created_at', label: 'Date', render: (r) => t(r.created_at) }, { key: 'booking_number', label: 'Booking', render: (r) => bk(r.booking_number) },
      { key: 'purpose', label: 'For', render: (r) => friendly(PURPOSE_LABEL, r.purpose) }, { key: 'kind', label: 'Kind', render: (r) => friendly(KIND_LABEL, r.kind) }, { key: 'method', label: 'Method', render: (r) => friendly(METHOD_LABEL, r.method) },
      { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
      { key: 'card_last4', label: 'Card', render: (r) => cardLabel(r.card_brand, r.card_last4) }, { key: 'next_retry_at', label: 'Next retry', render: (r) => t(r.next_retry_at) }]} />
  </>);
}

export async function Refunds({ ctx, status }: { ctx: Ctx; status?: string }) {
  const { rows } = await ctx.list<R>('refunds', { eq: status ? { status } : {}, limit: 200 });
  return (<>
    <PageHead title="Refunds" purpose="Every refund and where it is. Refunds waiting for a decision are decided on By day, within your limit; above it an Admin decides." />
    <Filters base="/staff/money?tab=refunds" name="status" value={status ?? ''} sp={{ tab: 'refunds', ...(status ? { status } : {}) }} options={[['', 'All'], ['pending_approval', 'Waiting for approval'], ['approved', 'Approved'], ['paid', 'Paid'], ['rejected', 'Rejected'], ['failed', 'Failed']]} />
    <Table<R> testId="refunds" rows={rows} empty="No refunds." cols={[{ key: 'created_at', label: 'Requested', render: (r) => t(r.created_at) }, { key: 'booking_number', label: 'Booking', render: (r) => bk(r.booking_number) },
      { key: 'reason', label: 'Reason', render: (r) => friendly(REFUND_REASON, r.reason) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
      { key: 'status', label: 'Status', render: (r) => r.status === 'pending_approval' ? <Link prefetch={false} className="link" href="/staff/money?tab=day">Waiting: decide it on By day</Link> : <Badge s={String(r.status)} /> },
      { key: 'due_by', label: 'Due by', render: (r) => d(r.due_by) }, { key: 'paid_at', label: 'Paid', render: (r) => t(r.paid_at) },
      { key: 'act', label: '', render: (r) => ['approved', 'processing', 'failed'].includes(String(r.status)) ? <Act ops action="refund_issue" payload={{ id: r.id }} label={r.status === 'failed' ? 'Issue again' : 'Issue the refund'} variant="primary"
          confirm={`Send ${$(r.amount_cents)} back to the card it was paid with. It is sent once, even if you press twice.`} refresh={['/staff/money']} done="Refund sent." /> : null }]} />
  </>);
}

export async function Deposits({ ctx }: { ctx: Ctx }) {
  const { rows } = await ctx.list<R>('deposits', { limit: 200 });
  return (<>
    <PageHead title="Deposits" purpose="Every deposit held or due, what was applied and when it is due back." />
    <Table<R> testId="deposits" rows={rows} empty="No deposits held or due." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => bk(r.booking_number) }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
      { key: 'method', label: 'Method', render: (r) => friendly(METHOD_LABEL, r.paid_method ?? r.method) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
      { key: 'applied_cents', label: 'Applied', num: true, render: (r) => $(r.applied_cents) }, { key: 'held_back_cents', label: 'Held back', num: true, render: (r) => $(r.held_back_cents) },
      { key: 'release_due_on', label: 'Release due', render: (r) => d(r.release_due_on) }, { key: 'released_cents', label: 'Released', num: true, render: (r) => $(r.released_cents) }]} />
  </>);
}
