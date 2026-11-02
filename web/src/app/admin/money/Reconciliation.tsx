import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';
import { ManualMonth, type ManualMonthData } from '@/features/manual/ManualMonth';
import { $, Badge, Card, PageHead, Table, d, t } from '@/features/admin/ui';

type R = Record<string, unknown>;
type Read = <T>(what: string, p?: Record<string, unknown>) => Promise<T>;

// Payments > Reconciliation (was /admin/reconciliation until r27): processor payouts matched to the payments, and the
// month of payments taken another way.
export async function Reconciliation({ read, userId, month: m }: { read: Read; userId: string; month?: string }) {
  const month = /^\d{4}-\d{2}-\d{2}$/.test(m ?? '') ? m : undefined;
  const [rows, manual] = await Promise.all([read<Array<R & { items: R[] }>>('reconciliation'),
    door<ManualMonthData>(userId, 'ops_read', 'manual_payments_month', { month }).catch(() => null)]);
  const RF = ['/admin/money'];
  return (<>
    <PageHead title="Payout reconciliation" purpose="Each processor payout against the payments it holds. Match what is left over to a payment."><Act action="reconcile_record" label="Record a processor payout" variant="primary" refresh={RF} fields={[{ name: 'payout_ref', label: 'Payout reference', required: true }, { name: 'paid_on', label: 'Paid on', type: 'date', required: true }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'items', label: 'Items (from the processor report)', type: 'json', value: [] }]} /></PageHead>
    {rows.length ? rows.map((r) => (
      <Card key={String(r.id)} title={`${String(r.processor_payout_ref)} · ${d(r.paid_on)}`} aside={<span className="small"><Badge s={String(r.status)} /> {$(r.amount_cents)}, unmatched {$(r.unmatched_cents)}</span>}>
        <Table rows={r.items} empty="Nothing to match. Processor payouts appear here each evening to compare with the payments." cols={[{ key: 'occurred_at', label: 'When', render: (x) => t(x.occurred_at) }, { key: 'kind', label: 'Kind' }, { key: 'processor_payment_ref', label: 'Processor ref' }, { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }, { key: 'fee_cents', label: 'Fee', num: true, render: (x) => $(x.fee_cents) },
          { key: 'status', label: 'Status', render: (x) => <Badge s={String(x.status)} /> }, { key: 'act', label: '', render: (x) => x.status !== 'matched' ? <Act action="reconcile_match" payload={{ item: x.id }} label="Match" fields={[{ name: 'payment', label: 'Payment id' }, { name: 'note', label: 'Note' }]} refresh={RF} /> : null }]} />
      </Card>)) : <p className="ad-empty">No processor payouts recorded.</p>}
    {manual && <ManualMonth data={manual} base="/admin/money?tab=reconciliation" />}
  </>);
}
