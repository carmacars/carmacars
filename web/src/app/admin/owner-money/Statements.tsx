import Link from '@/components/Link';
import type { AdminPage } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { monthOf } from '@/features/owner/Blocks';
import { $, Badge, Filters, PageHead, Table, Tiles, d } from '@/features/admin/ui';

type R = Record<string, unknown>;
const lastMonth = () => { const n = new Date(); return new Date(Date.UTC(n.getUTCFullYear(), n.getUTCMonth() - 1, 1)).toISOString().slice(0, 10); };

// Owner statements (11-statements-and-reports.md section 2).
export async function Statements({ ctx: { list }, sp }: { ctx: AdminPage; sp: Record<string, string | undefined> }) {
  const [{ rows }, owners] = await Promise.all([list('owner_statements', { eq: sp.status ? { status: sp.status } : {}, order: 'statement_month', limit: 300 }), list<{ id: string; legal_name: string; kind?: string }>('owners', { order: 'legal_name', asc: true, limit: 500 })]);
  return (<>
    <PageHead title="Owner statements">
      <Act action="statements_build_all" label="Build all for a month" fields={[{ name: 'month', label: 'Month (first day)', type: 'date', required: true, value: lastMonth() }]} refresh={['/admin/owner-money']} />
      <Act action="statement_build" label="Build one" variant="primary" testId="statement-build" go="/admin/statements/{id}" fields={[{ name: 'owner', label: 'Owner', type: 'select', required: true, options: owners.rows.filter((o) => o.kind !== 'company').map((o) => [o.id, o.kind === 'partner' ? `${o.legal_name} (partner)` : o.legal_name]) }, { name: 'month', label: 'Month (first day)', type: 'date', required: true, value: lastMonth() }]} />
    </PageHead>
    <Tiles items={[{ k: 'Drafts to approve', v: String(rows.filter((r) => r.status === 'draft').length), href: '/admin/owner-money?tab=statements&status=draft', warn: rows.some((r) => r.status === 'draft') },
      { k: 'Approved', v: String(rows.filter((r) => r.status === 'approved').length), href: '/admin/owner-money?tab=statements&status=approved' },
      { k: 'Paid', v: String(rows.filter((r) => r.status === 'paid').length), href: '/admin/owner-money?tab=statements&status=paid' }]} />
    <Filters base="/admin/owner-money?tab=statements" name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['draft', 'Draft'], ['approved', 'Approved'], ['paid', 'Paid'], ['void', 'Void']]} />
    <Table<R> testId="statements" rows={rows} empty="No statements yet. Owner statements are drafted 5 days before the payout date, then wait here for your approval." cols={[{ key: 'statement_number', label: 'Statement', render: (r) => <Link prefetch={false} className="link" href={`/admin/statements/${String(r.id)}`}>{String(r.statement_number ?? 'draft')}</Link> },
      { key: 'owner_name', label: 'Owner' }, { key: 'statement_month', label: 'Month', render: (r) => monthOf(String(r.statement_month)) }, { key: 'version', label: 'v', num: true },
      { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'owner_revenue_cents', label: 'Owner Revenue', num: true, render: (r) => $(r.owner_revenue_cents) },
      { key: 'deductions_cents', label: 'Deductions', num: true, render: (r) => $(r.deductions_cents) }, { key: 'payout_cents', label: 'Payout', num: true, render: (r) => $(r.payout_cents) }, { key: 'payout_date', label: 'Payout date', render: (r) => d(r.payout_date) }]} />
  </>);
}
