import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Filters, PageHead, Table, t, d } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payouts', path: '/admin/payouts', noindex: true, description: 'Approve payouts and record them sent.' });
type R = Record<string, unknown>;

// Payouts (11-statements-and-reports.md section 6): approve (a second Admin where both principals must), then record the transfer.
export default async function Payouts({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/payouts'), searchParams]);
  const { rows } = await list('payouts', { eq: sp.status ? { status: sp.status } : {}, limit: 200 });
  const R = ['/admin/payouts'];
  return (<>
    <PageHead title="Payouts" />
    <Filters base="/admin/payouts" name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['pending_approval', 'Waiting for approval'], ['approved', 'Approved'], ['paid', 'Paid'], ['cancelled', 'Cancelled']]} />
    <Table<R> testId="payouts" rows={rows} empty="No payouts." cols={[{ key: 'created_at', label: 'Created', render: (r) => t(r.created_at) }, { key: 'payee', label: 'Payee', render: (r) => String(r.owner_name ?? r.investor_name ?? r.payee_type) }, { key: 'kind', label: 'Kind' },
      { key: 'statement', label: 'Statement', render: (r) => r.owner_statement_id ? <Link className="link" href={`/admin/statements/${String(r.owner_statement_id)}`}>open</Link> : null },
      { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'scheduled_for', label: 'Scheduled', render: (r) => d(r.scheduled_for) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
      { key: 'reference', label: 'Reference' }, { key: 'paid_at', label: 'Paid', render: (r) => t(r.paid_at) },
      { key: 'act', label: 'Actions', render: (r) => <span className="ad-actions">
        {['draft', 'pending_approval'].includes(String(r.status)) && <Act action="payout_approve" payload={{ id: r.id }} label={r.approved_by ? 'Second approval' : 'Approve'} variant="primary" refresh={R} />}
        {['approved', 'sent'].includes(String(r.status)) && <Act action="payout_paid" payload={{ id: r.id }} label="Record sent" refresh={R} fields={[{ name: 'reference', label: 'Transfer reference', required: true }, { name: 'paid_at', label: 'Sent', type: 'datetime', value: new Date().toISOString() }]} />}
        {['draft', 'pending_approval', 'approved'].includes(String(r.status)) && <Act action="payout_cancel" payload={{ id: r.id }} label="Cancel" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={R} />}</span> }]} />
  </>);
}
