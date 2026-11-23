import Link from '@/components/Link';
import { LineChart } from '@/components/portal-ui/charts';
import { $, Card, Table, Tiles, d, t } from '@/features/admin/ui';
import { freeCash, monthName, monthStep, type Dashboard } from './model';
import type { StripeCash } from './stripe-cash';

type Stripe = StripeCash | { error: string } | null;
const compact = (c: number) => { const v = c / 100; const a = Math.abs(v); return `${v < 0 ? '-' : ''}$${a >= 1e6 ? `${+(a / 1e6).toFixed(1)}M` : a >= 1e3 ? `${Math.round(a / 1e3)}k` : Math.round(a)}`; };

// Release 49 (3480): Admin > Company > Finance and Finance > Money > Finance. Read only: each figure links to the page
// where it is worked (payouts, refunds, insurer invoices, bank lines). The database decides who sees it.
export function FinanceOverview({ d: x, stripe, base, bookingBase }: { d: Dashboard; stripe: Stripe; base: '/admin' | '/staff'; bookingBase: string }) {
  const s = stripe && !('error' in stripe) ? stripe : null;
  const free = freeCash(x, s);
  const page = `${base}/finance`;
  const admin = base === '/admin';
  const links = {
    payouts: admin ? '/admin/owner-money?tab=payouts' : '/staff/owner-money?tab=statements',
    refunds: `${base}/money?tab=refunds`,
    deposits: `${base}/money?tab=deposits`,
    insurers: admin ? '/admin/insurers?tab=invoices' : '/staff/money',
    commissions: admin ? '/admin/money/commissions' : '/staff/money',
    expenses: admin ? '/admin/expenses' : '/staff/money',
    stripe: `${base}/money?tab=reconciliation`
  };
  const stale = x.bank.accounts.filter((a) => a.days_old === null || a.days_old > 7);
  const pnl = x.pnl;
  const m = x.money_in;
  const o = x.money_out;
  return (
    <div className="stack" data-testid="finance-overview">
      <p className="small" data-testid="finance-month">
        <Link prefetch={false} className="link" href={`${page}?month=${monthStep(x.month, -1)}`}>Earlier month</Link>
        {' · '}<b>{monthName(x.month)}</b>
        {x.month < x.today.slice(0, 8) + '01' ? <>{' · '}<Link prefetch={false} className="link" href={`${page}?month=${monthStep(x.month, 1)}`}>Later month</Link></> : null}
      </p>

      <Card title="Cash position" testId="finance-cash" aside={<span className="small muted">as at {t(x.as_of)}</span>}>
        <Tiles items={[
          { k: 'In the bank', v: x.bank.accounts.length ? $(x.bank.total_cad_cents) : 'No balance yet', sub: x.bank.accounts.length ? `${x.bank.accounts.length} account(s), from the latest import` : 'Import the RBC download below', href: `${page}?tab=bank`, warn: stale.length > 0 },
          { k: 'Stripe balance', v: s ? $(s.available_cents + s.pending_cents) : stripe ? 'Not read' : 'Not connected', sub: s ? `${$(s.available_cents)} available, ${$(s.pending_cents)} pending` : stripe && 'error' in stripe ? stripe.error : 'Stripe keys are not set here', href: links.stripe },
          { k: 'Stripe payouts on the way', v: s ? $(s.in_transit_cents) : '', sub: s ? (s.in_transit_count ? `${s.in_transit_count} payout(s), next ${d(s.next_arrival)}` : 'None') : '' },
          { k: 'Free cash', v: $(free), sub: 'after deposits held, payouts due, refunds owed and HST owed', warn: free < 0 }
        ]} />
        {stale.length ? <p className="small ad-late" data-testid="finance-stale">{stale.map((a) => `${a.nickname} (ending ${a.last4})`).join(', ')}: the balance is {stale.some((a) => a.days_old === null) ? 'missing' : 'more than a week old'}. Import this week&apos;s download.</p> : null}
        {x.bank.accounts.length ? <Table testId="finance-accounts" rows={x.bank.accounts} sort={false} cols={[
          { key: 'nickname', label: 'Account', render: (a) => `${a.nickname} · ${a.last4}` }, { key: 'currency', label: 'Currency' },
          { key: 'balance_cents', label: 'Balance', num: true, render: (a) => $(a.balance_cents) }, { key: 'as_of', label: 'As at', render: (a) => d(a.as_of) },
          { key: 'last_import_at', label: 'Last import', render: (a) => t(a.last_import_at) }]} /> : null}
      </Card>

      <Card title={`Money in, ${monthName(x.month)}`} testId="finance-in">
        <Tiles items={[
          { k: 'Rentals and charges', v: $(m.month_rentals_cents), sub: 'card and other payments taken (deposits are not income)', href: `${base}/money?tab=day` },
          { k: 'Owner fees', v: $(m.month_owner_fees_cents), sub: 'invoices and debits paid' },
          { k: 'From insurers', v: $(m.month_insurers_cents), sub: 'invoices paid in full this month', href: links.insurers },
          { k: 'Tips', v: $(m.month_tips_cents), sub: 'for the staff, not revenue' }
        ]} />
      </Card>

      <Card title="Held for others" testId="finance-held">
        <Tiles items={[
          { k: 'Deposits held as cash', v: $(x.deposits.cash_cents), sub: `${x.deposits.count} deposit(s); owed back unless applied`, href: links.deposits, warn: x.deposits.release_late > 0 },
          { k: 'Deposit holds on cards', v: $(x.deposits.holds_cents), sub: 'not money in the bank' },
          { k: 'Kept back for claims and tolls', v: $(x.deposits.held_back_cents) },
          { k: 'Refunds owed', v: $(o.refunds.owed_cents), sub: `${o.refunds.owed_count} waiting or not sent`, href: links.refunds, warn: o.refunds.owed_count > 0 }
        ]} />
        {x.deposits.release_late ? <p className="small ad-late">{x.deposits.release_late} deposit(s) are past their release date.</p> : null}
      </Card>

      <Card title={`Money out, ${monthName(x.month)}`} testId="finance-out">
        <Tiles items={[
          { k: 'Owner payouts due', v: $(o.owner_payouts.due_cents), sub: o.owner_payouts.due_count ? `${o.owner_payouts.due_count} payout(s), next ${d(o.owner_payouts.next_on)}` : 'None waiting', href: links.payouts, warn: o.owner_payouts.failed_count > 0 },
          { k: 'Owner payouts paid', v: $(o.owner_payouts.paid_month_cents), sub: 'paid on the 10th', href: links.payouts },
          { k: 'Commissions', v: $(o.commissions.paid_month_cents + o.commissions.partners_paid_month_cents), sub: `paid; ${$(o.commissions.due_cents)} approved and due, ${$(o.commissions.accruing_cents)} accruing`, href: links.commissions },
          { k: 'Expenses', v: $(o.expenses_month_cents), sub: 'with HST', href: links.expenses },
          { k: 'Refunds paid', v: $(o.refunds.paid_month_cents), href: links.refunds }
        ]} />
        {o.owner_payouts.failed_count ? <p className="small ad-late">{o.owner_payouts.failed_count} owner payout(s) failed: send them again from Owner money, Payouts.</p> : null}
      </Card>

      <Card title={`HST, ${d(x.hst.from)} to ${d(x.hst.to)}`} testId="finance-hst">
        <Tiles items={[
          { k: 'Collected', v: $(x.hst.collected_cents), sub: `renters ${$(x.hst.collected.renters)}, owners ${$(x.hst.collected.owners)}, insurers ${$(x.hst.collected.insurers)}` },
          { k: 'Paid (input tax credits)', v: $(x.hst.paid_cents), sub: `expenses ${$(x.hst.paid.expenses)}, payouts to registered owners ${$(x.hst.paid.payouts)}` },
          { k: x.hst.owed_cents >= 0 ? 'Owed to the CRA' : 'Refund from the CRA', v: $(Math.abs(x.hst.owed_cents)), sub: 'for the quarter so far', warn: x.hst.owed_cents > 0 }
        ]} />
        <p className="small muted">Renter HST counts on rentals that ended in the quarter; owner and insurer HST on the invoice date. An Insurance Fee never carries HST.</p>
        {x.hst.insurance_with_hst.length ? <p className="small ad-late" data-testid="finance-hst-problem">Insurance Fee lines charged HST (they must not): {x.hst.insurance_with_hst.map((i) => `${i.invoice_number} (${$(i.hst_cents)})`).join(', ')}. Correct these invoices.</p> : null}
      </Card>

      <Card title="Renter balances overdue" testId="finance-renters" aside={<span className="small">{$(x.renters_overdue.total_cents)} · {x.renters_overdue.count}</span>}>
        <Table testId="finance-renters-table" rows={x.renters_overdue.rows} empty="No renter owes money past the statement's 7 days." cols={[
          { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(r.booking_number)}?tab=money`}>{r.booking_number}</Link> },
          { key: 'renter', label: 'Renter', className: 'wrap' }, { key: 'open_cents', label: 'Owed', num: true, render: (r) => $(r.open_cents) },
          { key: 'since', label: 'Overdue since', render: (r) => d(r.since) }, { key: 'days', label: 'Days', num: true }]} />
      </Card>

      <Card title="Insurer invoices unpaid" testId="finance-insurers" aside={<span className="small">{$(x.insurers.total_cents)} · {x.insurers.count}</span>}>
        <Tiles items={[
          { k: '0 to 30 days', v: $(x.insurers.buckets.d0_30) }, { k: '31 to 60 days', v: $(x.insurers.buckets.d31_60), warn: x.insurers.buckets.d31_60 > 0 },
          { k: '61 to 90 days', v: $(x.insurers.buckets.d61_90), warn: x.insurers.buckets.d61_90 > 0 }, { k: 'Over 90 days', v: $(x.insurers.buckets.d90), warn: x.insurers.buckets.d90 > 0 }
        ]} />
        <Table testId="finance-insurers-table" rows={x.insurers.rows} empty="No insurer invoice is waiting for payment." cols={[
          { key: 'invoice_number', label: 'Invoice' }, { key: 'insurer', label: 'Insurer', className: 'wrap' },
          { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(r.booking_number)}?tab=money`}>{r.booking_number}</Link> },
          { key: 'claim_number', label: 'Claim' }, { key: 'balance_cents', label: 'Balance', num: true, render: (r) => $(r.balance_cents) },
          { key: 'sent_on', label: 'Sent', render: (r) => d(r.sent_on) }, { key: 'days', label: 'Days', num: true }]} />
      </Card>

      <Card title="Twelve months" testId="finance-pnl">
        <LineChart testId="finance-pnl-chart" title="Money in and out by month" fmt={compact} labels={pnl.map((p) => monthName(p.month).slice(0, 3))}
          series={[{ key: 'in', label: 'Money in', values: pnl.map((p) => p.in_cents), tone: 'ink' },
            { key: 'out', label: 'Money out', values: pnl.map((p) => p.refunds_cents + p.payouts_cents + p.commissions_cents + p.expenses_cents), tone: 'dash' },
            { key: 'net', label: 'Net', values: pnl.map((p) => p.net_cents), tone: 'accent' }]} />
        <Table testId="finance-pnl-table" rows={[...pnl].reverse()} sort={false} cols={[
          { key: 'month', label: 'Month', render: (p) => monthName(p.month) }, { key: 'in_cents', label: 'In', num: true, render: (p) => $(p.in_cents) },
          { key: 'refunds_cents', label: 'Refunds', num: true, render: (p) => $(p.refunds_cents) }, { key: 'payouts_cents', label: 'Payouts', num: true, render: (p) => $(p.payouts_cents) },
          { key: 'commissions_cents', label: 'Commissions', num: true, render: (p) => $(p.commissions_cents) }, { key: 'expenses_cents', label: 'Expenses', num: true, render: (p) => $(p.expenses_cents) },
          { key: 'net_cents', label: 'Net', num: true, render: (p) => <b className={p.net_cents < 0 ? 'ad-late' : undefined}>{$(p.net_cents)}</b> },
          { key: 'statement_net_cents', label: 'Monthly statement', num: true, render: (p) => (p.statement_net_cents === null ? '' : $(p.statement_net_cents)) }]} />
        <p className="small muted">Cash basis: money as it moved. The monthly statement column is the company&apos;s net from the built statement (earned basis), where one exists.</p>
      </Card>

      <Card title="Bank reconciliation" testId="finance-recon" tone={x.reconciliation.unmatched ? 'warn' : undefined}
        aside={<Link prefetch={false} className="link small" href={`${page}?tab=bank`}>Bank lines</Link>}>
        <Tiles items={[
          { k: 'Matched', v: `${x.reconciliation.matched} of ${x.reconciliation.total}`, sub: `${x.reconciliation.auto} by themselves` },
          { k: 'No match', v: String(x.reconciliation.unmatched), sub: x.reconciliation.unmatched ? `in ${$(x.reconciliation.unmatched_in_cents)}, out ${$(x.reconciliation.unmatched_out_cents)}; oldest ${d(x.reconciliation.oldest_unmatched)}` : 'All lines accounted for', href: `${page}?tab=bank`, warn: x.reconciliation.unmatched > 0 },
          { k: 'Set aside', v: String(x.reconciliation.ignored), sub: 'bank fees, transfers between accounts' },
          { k: 'Stripe payouts not yet in the bank', v: String(x.bank.stripe_payouts_open.length), sub: x.bank.stripe_payouts_open.length ? $(x.bank.stripe_payouts_open.reduce((a, p) => a + p.amount_cents, 0)) : 'last 14 days' }
        ]} />
        <p className="small muted">A line with no match after {x.unmatched_days} day(s) becomes a To do for Finance.</p>
      </Card>
    </div>
  );
}
