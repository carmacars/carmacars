import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, PageHead, Table, d, t } from '@/features/admin/ui';
import { CHANNELS, CHANNEL_LABEL, refundMaths, type Channel, type Ledger, type LedgerDay, type LedgerRow, type RefundItem } from './ledger';

// Payments (0144), for an Admin and for Finance: a date range and the methods, the totals of each day by method, the cash
// drawer expected against the count, every payment with friendly labels, and every refund requested anywhere with the
// policy maths, approved or declined in the same row. One screen in both portals; the database decides who may do what.
type R = Record<string, unknown>;

export function PaymentsView({ l, base, bookingBase }: { l: Ledger; base: string; bookingBase: string }) {
  const q = new URLSearchParams({ from: l.from, to: l.to, ...(l.methods.length ? { method: l.methods.join(',') } : {}) });
  const refresh = [base];
  const used = CHANNELS.filter((c) => l.totals[c] && (l.totals[c]!.in || l.totals[c]!.out || l.totals[c]!.count));
  const bk = (n: unknown) => (n ? <Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(String(n))}`}>{String(n)}</Link> : null);
  const sum = (k: 'in' | 'out') => used.reduce((a, c) => a + (l.totals[c]?.[k] ?? 0), 0);
  return (
    <>
      <PageHead title="Payments" kicker={l.from === l.to ? d(l.from) : `${d(l.from)} to ${d(l.to)}`}
        purpose="Every payment and refund by day and method, the cash drawer against the count, and the refunds waiting for a decision.">
        <a className="btn btn--ghost btn--sm" href={`/api/payments/export?${q.toString()}`} data-testid="payments-export" download>Export CSV</a>
      </PageHead>
      <form className="ad-filters pay-filters" method="get" action={base} data-testid="payments-filters">
        <label className="field"><span className="label">From</span><input className="input" type="date" name="from" defaultValue={l.from} data-testid="pay-from" /></label>
        <label className="field"><span className="label">To</span><input className="input" type="date" name="to" defaultValue={l.to} data-testid="pay-to" /></label>
        <fieldset className="pay-methods"><legend className="label">Methods (none ticked: all)</legend>
          {CHANNELS.map((c) => <label key={c} className="check"><input type="checkbox" name="method" value={c} defaultChecked={l.methods.includes(c)} data-testid={`pay-m-${c}`} /> <span>{CHANNEL_LABEL[c]}</span></label>)}
        </fieldset>
        <div className="row"><button className="btn btn--primary btn--sm" type="submit" data-testid="pay-apply">Show</button>
          <Link prefetch={false} className="btn btn--quiet btn--sm" href={base}>Today</Link></div>
      </form>

      <Card title="Refunds waiting" testId="refund-queue" tone={l.refunds.some((r) => r.status === 'pending_approval') ? 'next' : undefined}>
        <Table<RefundItem & R> rows={l.refunds as Array<RefundItem & R>} empty="No refund waiting. A refund requested anywhere (a cancellation, a booking, Finance) shows here." cols={[
          { key: 'created_at', label: 'Asked', render: (r) => <>{t(r.created_at)}{r.requested_by ? <span className="small muted"> by {r.requested_by}</span> : null}</> },
          { key: 'booking_number', label: 'Booking', render: (r) => <>{bk(r.booking_number)}{r.who ? <span className="small muted"> {r.who}</span> : null}</> },
          { key: 'reason_label', label: 'Why' },
          { key: 'maths', label: 'Policy', className: 'wrap', render: (r) => <span className="small" data-testid={`refund-maths-${r.booking_number}`}>{refundMaths(r)}</span> },
          { key: 'amount_cents', label: 'Refund', num: true, render: (r) => <b>{$(r.amount_cents)}</b> },
          { key: 'status', label: 'Status', render: (r) => <Badge s={r.status}>{r.status === 'pending_approval' ? 'Waiting' : undefined}</Badge> },
          { key: 'act', label: 'Decide', render: (r) => r.status === 'pending_approval' ? (
            <span className="ad-actions">
              {r.can_approve ? <Act ops action="refund_decide" payload={{ id: r.id, approve: true }} label="Approve" variant="primary" refresh={refresh} testId={`refund-approve-${r.booking_number}`} done="Approved." />
                : <span className="small muted">Above your limit: an Admin approves</span>}
              {r.can_decline && <Act ops action="refund_decide" payload={{ id: r.id, approve: false }} label="Decline" refresh={refresh} testId={`refund-decline-${r.booking_number}`}
                fields={[{ name: 'reason', label: 'Reason', required: true }]} done="Declined." />}
            </span>)
            : r.can_issue ? <Act ops action="refund_issue" payload={{ id: r.id }} label={r.status === 'failed' ? 'Issue again' : 'Issue the refund'} variant="primary" testId={`refund-issue-${r.booking_number}`}
                confirm={`Send ${$(r.amount_cents)} back the way it was paid. It is sent once, even if you press twice.`} refresh={refresh} done="Refund sent." /> : null }]} />
      </Card>

      <Card title="Totals by method" testId="payments-totals">
        <Table<R> rows={used.map((c) => ({ c, ...l.totals[c] }))} rowKey={(r) => String(r.c)} empty="No payments in these days." cols={[
          { key: 'c', label: 'Method', render: (r) => CHANNEL_LABEL[r.c as Channel] },
          { key: 'count', label: 'Payments', num: true },
          { key: 'in', label: 'Received', num: true, render: (r) => $(r.in) },
          { key: 'out', label: 'Refunded', num: true, render: (r) => $(r.out) },
          { key: 'net', label: 'Net', num: true, render: (r) => <b>{$(Number(r.in) - Number(r.out))}</b> }]} />
        {used.length > 1 && <p className="small" data-testid="payments-grand">All methods: received {$(sum('in'))}, refunded {$(sum('out'))}, net <b>{$(sum('in') - sum('out'))}</b>.</p>}
      </Card>

      <Card title="Each day" testId="payments-days">
        <Table<LedgerDay & R> rows={l.days as Array<LedgerDay & R>} rowKey={(r) => r.day} empty="No days." cols={[
          { key: 'day', label: 'Day', render: (r) => d(r.day) },
          { key: 'by_method', label: 'By method', className: 'wrap', render: (r) => <span className="small">{CHANNELS.filter((c) => r.by_method[c]).map((c) => `${CHANNEL_LABEL[c]} ${$(r.by_method[c]!.in - r.by_method[c]!.out)}`).join(' · ') || 'nothing'}</span> },
          { key: 'in_cents', label: 'Received', num: true, render: (r) => $(r.in_cents) },
          { key: 'out_cents', label: 'Refunded', num: true, render: (r) => $(r.out_cents) },
          { key: 'cash_expected_cents', label: 'Cash expected', num: true, render: (r) => $(r.cash_expected_cents) },
          { key: 'cash_counted_cents', label: 'Cash counted', num: true, render: (r) => r.cash_counted_cents === null ? <span className="muted small">not counted</span>
              : <span data-testid={`cash-counted-${r.day}`}>{$(r.cash_counted_cents)}{r.cash_counted_by ? <span className="small muted"> {r.cash_counted_by}</span> : null}</span> },
          { key: 'cash_difference_cents', label: 'Difference', num: true, render: (r) => r.cash_difference_cents === null ? '' : r.cash_difference_cents === 0
              ? <span className="small" data-testid={`cash-diff-${r.day}`}>balanced</span>
              : <span className="ad-flag ad-flag--red" data-testid={`cash-diff-${r.day}`}>{r.cash_difference_cents > 0 ? 'over ' : 'short '}{$(Math.abs(r.cash_difference_cents))}</span> },
          { key: 'act', label: '', render: (r) => <Act ops action="cash_drawer_count" payload={{ day: r.day }} label={r.cash_counted_cents === null ? 'Record the count' : 'Count again'} testId={`cash-count-${r.day}`}
              fields={[{ name: 'counted_cents', label: 'Cash counted in the drawer', type: 'money', required: true, value: r.cash_counted_cents ?? r.cash_expected_cents }, { name: 'note', label: 'Note' }]} refresh={refresh} done="Count recorded." /> }]} />
      </Card>

      <Card title={`Payments (${l.rows.length})`} testId="payments-rows">
        <Table<LedgerRow & R> rows={l.rows as Array<LedgerRow & R>} empty="No payments in these days for these methods." cols={[
          { key: 'at', label: 'When', render: (r) => t(r.at) },
          { key: 'channel_label', label: 'Method' },
          { key: 'what', label: 'What', className: 'wrap' },
          { key: 'how', label: 'How', className: 'wrap', render: (r) => <>{r.how}{r.reference ? <span className="small muted"> ref {r.reference}</span> : null}</> },
          { key: 'booking_number', label: 'Booking', render: (r) => <>{bk(r.booking_number)}{r.who ? <span className="small muted"> {r.who}</span> : null}</> },
          { key: 'amount_cents', label: 'Amount', num: true, render: (r) => <span className={r.direction === 'out' ? 'pay-out' : r.direction === 'held' ? 'muted' : undefined}>{r.direction === 'out' ? '-' : ''}{$(r.amount_cents)}</span> },
          { key: 'status', label: 'Status', render: (r) => r.status },
          { key: 'recorded_by', label: 'Recorded by', render: (r) => r.recorded_by ?? <span className="small muted">online</span> }]} />
      </Card>
    </>
  );
}
