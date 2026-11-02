import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, PageHead, Table, Tiles, t, label } from '@/features/admin/ui';
import { tabOf } from '@/features/admin/hubs';
import { Incidents } from './Incidents';
import { CarCell } from '@/features/admin/revamp/CarCell';
import { carPhotos } from '@/server/car-photos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Damage and claims', path: '/admin/damages', noindex: true, description: 'Damage found after a rental, incidents and insurance claims.' });
type R = Record<string, unknown>;

// Bookings > Damage and claims (r27, "We need less pages not more"): damage intake and its work queue
// (10-tolls-tickets-damages.md sections 4, 7 to 9), then the incidents and the claims, each a tab. /admin/incidents
// redirects to its tab.
export default async function Damages({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([page('/admin/damages'), searchParams]);
  const tab = tabOf(['damage', 'incidents', 'claims'] as const, sp.tab);
  if (tab !== 'damage') return <Incidents ctx={ctx} tab={tab} />;
  const { read, list } = ctx;
  const [rows, vehicles] = await Promise.all([read<R[]>('damages'), list<{ id: string; make: string; model: string; plate: string | null }>('vehicles', { order: 'make', asc: true, limit: 500 })]);
  const photos = await carPhotos(rows);
  return (<>
    <PageHead title="Damage" purpose="Damage found at a return or reported later: cost it, match it to a booking and charge it.">
      <Act action="damage_log" nest="damage" label="Log damage" variant="primary" go="/admin/damages/{id}" testId="damage-log" fields={[
        { name: 'vehicle_id', label: 'Vehicle', type: 'select', required: true, options: vehicles.rows.map((v) => [v.id, `${v.make} ${v.model} ${v.plate ?? ''}`]) },
        { name: 'found_at', label: 'Found', type: 'datetime', required: true, value: new Date().toISOString() }, { name: 'occurred_at', label: 'Happened (if known)', type: 'datetime' },
        { name: 'window_from', label: 'or could have happened from', type: 'datetime' }, { name: 'window_to', label: 'to', type: 'datetime' },
        { name: 'location', label: 'Where on the car', required: true }, { name: 'description', label: 'What it is', type: 'textarea', required: true },
        { name: 'cost_kind', label: 'Cost', type: 'select', options: [['estimate', 'Estimate'], ['invoice', 'Invoice']] }, { name: 'cost_cents', label: 'Amount', type: 'money' }, { name: 'shop_name', label: 'Shop' }]} />
    </PageHead>
    {/* r27: the queue in numbers, as the Now view's dark band */}
    <Tiles items={[{ k: 'In the queue', v: String(rows.length), sub: rows.length ? 'to cost, match or charge' : 'nothing waiting' },
      ...[...new Set(rows.map((r) => String(r.bucket)))].slice(0, 4).map((b) => ({ k: label(b).replace(/^./, (c) => c.toUpperCase()), v: String(rows.filter((r) => r.bucket === b).length) })),
      { k: 'Older than 7 days', v: String(rows.filter((r) => Number(r.age_days) > 7).length), warn: rows.some((r) => Number(r.age_days) > 7) }]} />
    <Card title="Work queue"><Table<R> testId="damages" rows={rows} empty="No damage waiting. Damage found at a return or reported later shows up here to cost and charge." cols={[{ key: 'intake_number', label: 'Intake', render: (r) => <Link prefetch={false} className="link" href={`/admin/damages/${String(r.id)}`}>{String(r.intake_number)}</Link> },
      { key: 'bucket', label: 'Queue', render: (r) => <Badge s="open">{label(r.bucket)}</Badge> }, { key: 'vehicle_name', label: 'Vehicle', render: (r) => <CarCell name={r.vehicle_name} photo={photos[String(r.vehicle_id)]} /> }, { key: 'found_at', label: 'Found', render: (r) => t(r.found_at) }, { key: 'location', label: 'Where' },
      { key: 'cost_cents', label: 'Cost', num: true, render: (r) => $(r.cost_cents) }, { key: 'matched', label: 'Matched', render: (r) => <>{label(r.matched_to)} {r.booking_number ? <BookingLink n={r.booking_number} /> : null}</> }, { key: 'age_days', label: 'Age (days)', num: true }]} /></Card>
  </>);
}
