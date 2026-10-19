import type { ReactNode } from 'react';
import { $, Card, Table, Tiles, d } from '@/features/admin/ui';

// A staff member's commissions (migration 0058): this month's progress (Sales: rental days against the target and the
// tier), the totals by status, and each commission. My sales (assistants and field staff) and Admin > Staff > Sales.
export interface MonthProgress {
  month: string; label: string; scheme: 'flat' | 'sales_tier' | 'override'; days: number; rate_bps: number; target_days: number; mid_days: number;
  tiers: Array<{ from_days: number; bps: number }>; progress_pct: number; next: { days: number; bps: number; to_go: number } | null; rises: string | null;
}
export interface CommissionRow {
  id: string; booking_number: string; kind: 'commission' | 'clawback' | 'adjustment'; month: string; month_label: string; rental_days: number; tier_days: number | null;
  base_cents: number; rate_bps: number; amount_cents: number; status: 'accruing' | 'pending_approval' | 'approved' | 'paid' | 'reversed' | 'void'; reason: string | null; note: string | null;
  scheme: string | null; earned_at: string | null; approved_at: string | null; paid_at: string | null; month_open: boolean;
  paid: { method: string; reference: string | null; paid_on: string; pay_period: string | null } | null;
}
export interface StaffCommissions {
  scheme: 'flat' | 'sales_tier' | 'override'; month: MonthProgress;
  totals: { not_earned: number; pending: number; approved: number; paid: number; reversed: number; earned: number };
  rows: CommissionRow[];
}

export const pctBps = (bps: number) => `${bps % 100 === 0 ? bps / 100 : (bps / 100).toFixed(2)}%`;
const METHOD: Record<string, string> = { e_transfer: 'e-Transfer', bank_transfer: 'bank transfer', wise: 'Wise', cash: 'cash', other: 'another way', pay_statement: 'pay statement' };

/** A commission's status in words. */
export function statusWords(r: CommissionRow): string {
  if (r.kind === 'clawback') return r.status === 'paid' ? 'Reversed after payment, taken off a payment' : 'Reversed after payment, taken off your next payment';
  if (r.kind === 'adjustment') return r.status === 'paid' ? 'Adjustment, paid' : r.status === 'approved' ? 'Adjustment, approved' : 'Adjustment, pending approval';
  switch (r.status) {
    case 'accruing': return 'Not earned yet';
    case 'pending_approval': return r.month_open ? 'Pending approval (after the month ends)' : 'Pending approval';
    case 'approved': return 'Approved, to be paid';
    case 'paid': return r.paid ? `Paid ${d(r.paid.paid_on)}, ${METHOD[r.paid.method] ?? r.paid.method}${r.paid.method === 'pay_statement' && r.paid.pay_period ? ` of ${d(r.paid.pay_period)}` : r.paid.reference ? ` ${r.paid.reference}` : ''}` : 'Paid';
    case 'reversed': return 'Reversed';
    default: return 'No commission';
  }
}

/** The month's progress toward the target, as a bar (Sales), or the flat rate. */
export function MonthTarget({ m, own }: { m: MonthProgress; own: boolean }) {
  if (m.scheme !== 'sales_tier') {
    return <p className="small" data-testid="commission-rate">{own ? 'Your' : 'Their'} commission: {pctBps(m.rate_bps)} of the rental charge of each rental {own ? 'you' : 'they'} source{m.scheme === 'override' ? ' (a rate set by an Admin)' : ''}.</p>;
  }
  return (
    <div className="stack" data-testid="sales-target">
      <p className="small"><b>{m.label}: {m.days} of {m.target_days} rental days.</b> {own ? 'Your' : 'Their'} rate now: <b>{pctBps(m.rate_bps)}</b>{m.rises ? `, ${m.rises}` : ', the top tier'}.</p>
      <div role="progressbar" aria-label={`Rental days this month: ${m.days} of the ${m.target_days} target`} aria-valuemin={0} aria-valuemax={m.target_days} aria-valuenow={Math.min(m.days, m.target_days)}
        style={{ position: 'relative', height: '0.9rem', background: 'var(--grey-100, #eee)', border: '1px solid var(--grey-300, #ccc)', borderRadius: '999px', overflow: 'hidden', maxWidth: '40rem' }}>
        <span style={{ display: 'block', height: '100%', width: `${m.progress_pct}%`, background: 'var(--red-600, #c00)' }} />
        <span aria-hidden="true" style={{ position: 'absolute', top: 0, bottom: 0, left: `${Math.round(100 * m.mid_days / Math.max(m.target_days, 1))}%`, borderLeft: '2px solid var(--text, #000)' }} />
      </div>
      <p className="small muted">Tiers: {m.tiers.map((x, i) => (i === 0 ? `under ${m.tiers[1]?.from_days ?? m.mid_days} days ${pctBps(x.bps)}` : `from ${x.from_days} days ${pctBps(x.bps)}`)).join(', ')}. The month&apos;s tier applies to all of that month&apos;s rentals; days count when a rental is completed and paid.</p>
    </div>
  );
}

export function Commissions({ c, own, compact, rowAction }: { c: StaffCommissions; own: boolean; compact?: boolean; rowAction?: (r: CommissionRow) => ReactNode }) {
  const tot = c.totals;
  if (compact) {
    return (
      <section className="fd-card stack" aria-labelledby="cm-t" data-testid="commissions">
        <h2 className="d4" id="cm-t">Commissions</h2>
        <MonthTarget m={c.month} own={own} />
        <ul className="fd-shots" data-testid="commission-totals">
          <li><span>Not earned yet</span><span>{$(tot.not_earned)}</span></li>
          <li><span>Pending approval</span><span>{$(tot.pending)}</span></li>
          <li><span>Approved</span><span>{$(tot.approved)}</span></li>
          <li><span>Paid</span><span>{$(tot.paid)}</span></li>
          <li><span>Reversed</span><span>{$(tot.reversed)}</span></li>
        </ul>
        {c.rows.length ? <ul className="fd-shots" data-testid="commission-rows">{c.rows.map((r) => (
          <li key={r.id}><span>{r.booking_number} · {r.month_label}</span><span>{$(r.amount_cents)} · {statusWords(r)}</span></li>))}</ul>
          : <p className="small muted">No commissions yet.</p>}
      </section>
    );
  }
  return (
    <Card title="Commissions" testId="commissions">
      <MonthTarget m={c.month} own={own} />
      <div data-testid="commission-totals"><Tiles items={[
        { k: 'Earned', v: $(tot.earned), sub: 'pending, approved and paid, less reversals' },
        { k: 'Pending approval', v: $(tot.pending) },
        { k: 'Approved', v: $(tot.approved), sub: 'to be paid' },
        { k: 'Paid', v: $(tot.paid) },
        { k: 'Reversed', v: $(tot.reversed), warn: tot.reversed > 0 },
        { k: 'Not earned yet', v: $(tot.not_earned), sub: 'rentals ahead or not paid in full' }
      ]} /></div>
      <Table<CommissionRow & Record<string, unknown>> testId="commission-rows" caption="Commissions" rows={c.rows as Array<CommissionRow & Record<string, unknown>>} rowKey={(r) => r.id}
        empty={own ? 'No commissions yet. Mark a rental "I sourced this client" when you found the renter.' : 'No commissions yet.'} cols={[
          { key: 'booking_number', label: 'Booking' },
          { key: 'month_label', label: 'Month' },
          { key: 'rental_days', label: 'Days', num: true, render: (r) => (r.kind === 'commission' ? r.rental_days : '') },
          { key: 'base_cents', label: 'Rental charge', num: true, render: (r) => $(r.base_cents) },
          { key: 'rate_bps', label: 'Rate', num: true, render: (r) => pctBps(r.rate_bps) },
          { key: 'amount_cents', label: 'Commission', num: true, render: (r) => $(r.amount_cents) },
          { key: 'status', label: 'Status', className: 'wrap', render: (r) => <span data-testid={`commission-status-${r.booking_number}-${r.kind}`}>{statusWords(r)}{r.reason ? <span className="ad-sub">{r.reason}</span> : null}{r.note ? <span className="ad-sub">{r.note}</span> : null}</span> },
          ...(rowAction ? [{ key: 'act', label: 'Actions', render: (r: CommissionRow & Record<string, unknown>) => rowAction(r) }] : [])]} />
      <ul className="small">
        <li>A commission counts on a rental {own ? 'you' : 'they'} marked &quot;I sourced this client&quot;, or that an Admin credited. It is the rate on the rental charge before tax, after discounts, less refunds.</li>
        <li>It is earned when the rental is completed and paid in full. None is earned on a cancelled, refunded, unpaid or charged-back rental, or on {own ? 'your' : 'their'} own or household rental.</li>
        <li>An Admin approves each commission (a Sales month after it ends), then records the payment. A refund or chargeback after payment is taken off the next payment.</li>
      </ul>
    </Card>
  );
}
