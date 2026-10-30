import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';
import { ManualMonth, type ManualMonthData } from '@/features/manual/ManualMonth';
import Link from 'next/link';
import { $, Badge, Card, PageHead, Table, d, t } from '@/features/admin/ui';
import { KIND_LABEL, friendly } from '@/features/money/ledger';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payout reconciliation', path: '/staff/reconciliation', noindex: true, description: 'Match processor payouts to payments.' });
type R = Record<string, unknown>;

// Finance's daily reconciliation (05-va.md section 2): processor payouts against the payments; an unmatched
// item is matched to a payment; anything still unmatched goes to an Admin at the closing check.
export default async function VaReconciliation({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
  const [{ read, user, aal }, sp] = await Promise.all([vaPage('/staff/reconciliation', ['finance']), searchParams]);
  const month = /^\d{4}-\d{2}-\d{2}$/.test(sp.month ?? '') ? sp.month : undefined;
  const [rows, manual] = await Promise.all([read<Array<R & { items: R[] }>>('reconciliation'),
    door<ManualMonthData>(user.id, 'ops_read', 'manual_payments_month', { month }, aal).catch(() => null)]);
  const RF = ['/staff/reconciliation'];
  return (<>
    <p className="small"><Link prefetch={false} className="link" href="/staff/payments" data-testid="to-payments-by-day">Payments by day</Link>: every payment of a day by method (card, e-Transfer, cash, cheque, platform, insurer), the cash drawer and the refunds to decide, with an export.</p>
    <PageHead title="Payout reconciliation"><Act action="reconcile_record" label="Record a processor payout" variant="primary" testId="reconcile-record" refresh={RF}
      fields={[{ name: 'payout_ref', label: 'Payout reference', required: true }, { name: 'paid_on', label: 'Paid on', type: 'date', required: true }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'items', label: 'Items (from the processor report)', type: 'json', value: [] }]} done="Payout recorded." /></PageHead>
    {rows.length ? rows.map((r) => (
      <Card key={String(r.id)} title={`${String(r.processor_payout_ref)} · ${d(r.paid_on)}`} aside={<span className="small"><Badge s={String(r.status)} /> {$(r.amount_cents)}, unmatched {$(r.unmatched_cents)}</span>}>
        <Table rows={r.items} empty="No items." cols={[{ key: 'occurred_at', label: 'When', render: (x) => t(x.occurred_at) }, { key: 'kind', label: 'Kind', render: (x) => friendly(KIND_LABEL, x.kind) }, { key: 'processor_payment_ref', label: 'Processor ref' }, { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }, { key: 'fee_cents', label: 'Fee', num: true, render: (x) => $(x.fee_cents) },
          { key: 'status', label: 'Status', render: (x) => <Badge s={String(x.status)} /> }, { key: 'act', label: '', render: (x) => x.status !== 'matched' ? <Act action="reconcile_match" payload={{ item: x.id }} label="Match" fields={[{ name: 'payment', label: 'Payment id' }, { name: 'note', label: 'Note' }]} refresh={RF} /> : null }]} />
      </Card>)) : <p className="ad-empty" data-testid="reconcile-empty">No processor payouts recorded.</p>}
    {manual && <ManualMonth data={manual} base="/staff/reconciliation" />}
    <p className="small muted">Anything still unmatched at the closing check goes to an Admin.</p>
  </>);
}
