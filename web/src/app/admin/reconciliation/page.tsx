import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';
import { ManualMonth, type ManualMonthData } from '@/features/manual/ManualMonth';
import { $, Badge, Card, PageHead, Table, d, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payout reconciliation', path: '/admin/reconciliation', noindex: true, description: 'Match processor payouts to payments.' });
type R = Record<string, unknown>;

export default async function Reconciliation({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/reconciliation'), searchParams]);
  const month = /^\d{4}-\d{2}-\d{2}$/.test(sp.month ?? '') ? sp.month : undefined;
  const [rows, manual] = await Promise.all([read<Array<R & { items: R[] }>>('reconciliation'),
    door<ManualMonthData>(user.id, 'ops_read', 'manual_payments_month', { month }).catch(() => null)]);
  return (<>
    <PageHead title="Payout reconciliation"><Act action="reconcile_record" label="Record a processor payout" variant="primary" refresh={['/admin/reconciliation']} fields={[{ name: 'payout_ref', label: 'Payout reference', required: true }, { name: 'paid_on', label: 'Paid on', type: 'date', required: true }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'items', label: 'Items (from the processor report)', type: 'json', value: [] }]} /></PageHead>
    {rows.length ? rows.map((r) => (
      <Card key={String(r.id)} title={`${String(r.processor_payout_ref)} · ${d(r.paid_on)}`} aside={<span className="small"><Badge s={String(r.status)} /> {$(r.amount_cents)}, unmatched {$(r.unmatched_cents)}</span>}>
        <Table rows={r.items} empty="Nothing to match. Processor payouts appear here each evening to compare with the payments." cols={[{ key: 'occurred_at', label: 'When', render: (x) => t(x.occurred_at) }, { key: 'kind', label: 'Kind' }, { key: 'processor_payment_ref', label: 'Processor ref' }, { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }, { key: 'fee_cents', label: 'Fee', num: true, render: (x) => $(x.fee_cents) },
          { key: 'status', label: 'Status', render: (x) => <Badge s={String(x.status)} /> }, { key: 'act', label: '', render: (x) => x.status !== 'matched' ? <Act action="reconcile_match" payload={{ item: x.id }} label="Match" fields={[{ name: 'payment', label: 'Payment id' }, { name: 'note', label: 'Note' }]} refresh={['/admin/reconciliation']} /> : null }]} />
      </Card>)) : <p className="ad-empty">No processor payouts recorded.</p>}
    {manual && <ManualMonth data={manual} base="/admin/reconciliation" />}
  </>);
}
