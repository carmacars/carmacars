import { pageMeta } from '@/features/seo/meta';
import { periodOf } from '@/features/owner/period';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { vaPage } from '@/server/va';
import { tabOf } from '@/features/admin/hubs';
import { $, Badge, PageHead, Table, Tiles, d } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner money', path: '/staff/owner-money', noindex: true, description: 'Owner invoices and owner statements.' });

type R = Record<string, unknown>;
const TABS = ['invoices', 'statements'] as const;
const INV: Array<[string, string]> = [['', 'All'], ['open', 'Open'], ['partly_paid', 'Partly paid'], ['failed', 'Failed'], ['in_arrears', 'In arrears']];
const ST: Array<[string, string]> = [['', 'All'], ['draft', 'Draft'], ['approved', 'Approved'], ['paid', 'Paid'], ['void', 'Void']];

// Finance > Owner money (r27 consolidation: Admin's Owner money for the finance role): every owner invoice and owner
// statement, read only (recording an owner's payment is on Money > To handle; approving a statement stays Admin's). The
// rows come through va_list (finance lists owner_invoices and owner_statements, migration 0031).
export default async function StaffOwnerMoney({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([vaPage('/staff/owner-money', ['finance']), searchParams]);
  const tab = tabOf(TABS, sp.tab);
  if (tab === 'statements') {
    const status = ST.some(([k]) => k === sp.status) ? sp.status ?? '' : '';
    const { rows } = await list<R>('owner_statements', { eq: status ? { status } : {}, order: 'statement_month', limit: 300 });
    return (<>
      <PageHead title="Owner statements" purpose="What each owner earned each month. Drafts wait for an Admin's approval; add notes from the statement task." />
      <Tiles items={[{ k: 'Drafts', v: String(rows.filter((r) => r.status === 'draft').length), href: '/staff/owner-money?tab=statements&status=draft' },
        { k: 'Approved', v: String(rows.filter((r) => r.status === 'approved').length), href: '/staff/owner-money?tab=statements&status=approved' },
        { k: 'Paid', v: String(rows.filter((r) => r.status === 'paid').length), href: '/staff/owner-money?tab=statements&status=paid' }]} />
      <ListFilters id="staff-owner-money-status" base="/staff/owner-money?tab=statements" sp={{ tab: 'statements', ...(status ? { status } : {}) }} chips={{ name: 'status', label: 'Status', value: status, options: ST }} />
      <Table<R> testId="statements" rows={rows} empty="No statements yet." cols={[{ key: 'statement_number', label: 'Statement', render: (r) => String(r.statement_number ?? 'draft') },
        { key: 'owner_name', label: 'Owner' }, { key: 'statement_month', label: 'Period', render: (r) => periodOf(r as unknown as { statement_month: string }) },
        { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'owner_revenue_cents', label: 'Owner Revenue', num: true, render: (r) => $(r.owner_revenue_cents) },
        { key: 'deductions_cents', label: 'Deductions', num: true, render: (r) => $(r.deductions_cents) }, { key: 'payout_cents', label: 'Payout', num: true, render: (r) => $(r.payout_cents) }, { key: 'not_collected_cents', label: 'Not yet collected', num: true, render: (r) => Number(r.not_collected_cents ?? 0) > 0 ? <span data-testid="not-collected" title="Of this, this much is not yet collected (revenue counts when earned)">{$(r.not_collected_cents)}</span> : '' }, { key: 'payout_date', label: 'Payout date', render: (r) => d(r.payout_date) }]} />
    </>);
  }
  const status = INV.some(([k]) => k === sp.status) ? sp.status ?? '' : '';
  const { rows } = await list<R>('owner_invoices', { eq: status ? { status } : {}, order: 'billing_date', limit: 300 });
  return (<>
    <PageHead title="Owner invoices" purpose="What owners owe. Record a payment an owner made another way on Money > To handle." />
    <Tiles items={[{ k: 'Open', v: String(rows.filter((r) => r.status === 'open' || r.status === 'partly_paid').length), href: '/staff/owner-money?tab=invoices&status=open' },
      { k: 'Failed', v: String(rows.filter((r) => r.status === 'failed').length), href: '/staff/owner-money?tab=invoices&status=failed', warn: rows.some((r) => r.status === 'failed') },
      { k: 'Paid', v: String(rows.filter((r) => r.status === 'paid').length), href: '/staff/owner-money?tab=invoices&status=paid' }]} />
    <ListFilters id="staff-owner-money-status" base="/staff/owner-money?tab=invoices" sp={{ tab: 'invoices', ...(status ? { status } : {}) }} chips={{ name: 'status', label: 'Status', value: status, options: INV }} />
    <Table<R> testId="owner-invoices" rows={rows} empty="No owner invoices." cols={[{ key: 'invoice_number', label: 'Invoice' }, { key: 'owner_name', label: 'Owner' },
      { key: 'billing_date', label: 'Billed', render: (r) => d(r.billing_date) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
      { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) }, { key: 'balance_cents', label: 'Balance', num: true, render: (r) => $(r.balance_cents) }]} />
  </>);
}
