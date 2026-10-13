import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, PageHead, Table, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Damage', path: '/admin/damages', noindex: true, description: 'Damage found after a rental.' });
type R = Record<string, unknown>;

// Damage intake and its work queue (10-tolls-tickets-damages.md sections 4, 7 to 9).
export default async function Damages() {
  const { read, list } = await page('/admin/damages');
  const [rows, vehicles] = await Promise.all([read<R[]>('damages'), list<{ id: string; make: string; model: string; plate: string | null }>('vehicles', { order: 'make', asc: true, limit: 500 })]);
  return (<>
    <PageHead title="Damage">
      <Act action="damage_log" nest="damage" label="Log damage" variant="primary" go="/admin/damages/{id}" testId="damage-log" fields={[
        { name: 'vehicle_id', label: 'Vehicle', type: 'select', required: true, options: vehicles.rows.map((v) => [v.id, `${v.make} ${v.model} ${v.plate ?? ''}`]) },
        { name: 'found_at', label: 'Found', type: 'datetime', required: true, value: new Date().toISOString() }, { name: 'occurred_at', label: 'Happened (if known)', type: 'datetime' },
        { name: 'window_from', label: 'or could have happened from', type: 'datetime' }, { name: 'window_to', label: 'to', type: 'datetime' },
        { name: 'location', label: 'Where on the car', required: true }, { name: 'description', label: 'What it is', type: 'textarea', required: true },
        { name: 'cost_kind', label: 'Cost', type: 'select', options: [['estimate', 'Estimate'], ['invoice', 'Invoice']] }, { name: 'cost_cents', label: 'Amount', type: 'money' }, { name: 'shop_name', label: 'Shop' }]} />
    </PageHead>
    <Card title="Work queue"><Table<R> testId="damages" rows={rows} empty="No damage waiting." cols={[{ key: 'intake_number', label: 'Intake', render: (r) => <Link prefetch={false} className="link" href={`/admin/damages/${String(r.id)}`}>{String(r.intake_number)}</Link> },
      { key: 'bucket', label: 'Queue', render: (r) => <Badge s="open">{label(r.bucket)}</Badge> }, { key: 'vehicle_name', label: 'Vehicle' }, { key: 'found_at', label: 'Found', render: (r) => t(r.found_at) }, { key: 'location', label: 'Where' },
      { key: 'cost_cents', label: 'Cost', num: true, render: (r) => $(r.cost_cents) }, { key: 'matched', label: 'Matched', render: (r) => <>{label(r.matched_to)} {r.booking_number ? <BookingLink n={r.booking_number} /> : null}</> }, { key: 'age_days', label: 'Age (days)', num: true }]} /></Card>
  </>);
}
