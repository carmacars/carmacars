import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, PageHead, Table, d, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payout reconciliation', path: '/admin/reconciliation', noindex: true, description: 'Match processor payouts to payments.' });
type R = Record<string, unknown>;

export default async function Reconciliation() {
  const { read } = await page('/admin/reconciliation');
  const rows = await read<Array<R & { items: R[] }>>('reconciliation');
  return (<>
    <PageHead title="Payout reconciliation"><Act action="reconcile_record" label="Record a processor payout" variant="primary" refresh={['/admin/reconciliation']} fields={[{ name: 'payout_ref', label: 'Payout reference', required: true }, { name: 'paid_on', label: 'Paid on', type: 'date', required: true }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'items', label: 'Items (from the processor report)', type: 'json', value: [] }]} /></PageHead>
    {rows.length ? rows.map((r) => (
      <Card key={String(r.id)} title={`${String(r.processor_payout_ref)} · ${d(r.paid_on)}`} aside={<span className="small"><Badge s={String(r.status)} /> {$(r.amount_cents)}, unmatched {$(r.unmatched_cents)}</span>}>
        <Table rows={r.items} empty="No items." cols={[{ key: 'occurred_at', label: 'When', render: (x) => t(x.occurred_at) }, { key: 'kind', label: 'Kind' }, { key: 'processor_payment_ref', label: 'Processor ref' }, { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }, { key: 'fee_cents', label: 'Fee', num: true, render: (x) => $(x.fee_cents) },
          { key: 'status', label: 'Status', render: (x) => <Badge s={String(x.status)} /> }, { key: 'act', label: '', render: (x) => x.status !== 'matched' ? <Act action="reconcile_match" payload={{ item: x.id }} label="Match" fields={[{ name: 'payment', label: 'Payment id' }, { name: 'note', label: 'Note' }]} refresh={['/admin/reconciliation']} /> : null }]} />
      </Card>)) : <p className="ad-empty">No processor payouts recorded.</p>}
  </>);
}
