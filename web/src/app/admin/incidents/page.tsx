import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, PageHead, Table, Tabs, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Incidents and claims', path: '/admin/incidents', noindex: true, description: 'Incidents and claims.' });
type R = Record<string, unknown>;

export default async function Incidents({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/incidents'), searchParams]);
  const tab = sp.tab ?? 'incidents';
  const vehicles = await list<{ id: string; make: string; model: string; plate: string | null }>('vehicles', { order: 'make', asc: true, limit: 500 });
  const head = (<><PageHead title="Incidents and claims"><Act action="incident_open" label="Open an incident" variant="primary" go="/admin/incidents/{id}" fields={[
    { name: 'kind', label: 'Kind', type: 'select', required: true, options: ['accident', 'damage_found_later', 'damage_at_return', 'breakdown', 'theft', 'vandalism', 'late_return', 'non_return', 'tracker_tampering', 'impound', 'other'].map((k) => [k, label(k)] as [string, string]) },
    { name: 'vehicle', label: 'Vehicle', type: 'select', required: true, options: vehicles.rows.map((v) => [v.id, `${v.make} ${v.model} ${v.plate ?? ''}`]) },
    { name: 'details', label: 'Details (what, where, when, drivable)', type: 'json', value: { description: '', place: '', drivable: true } }]} /></PageHead>
    <Tabs current={`/admin/incidents?tab=${tab}`} items={[['/admin/incidents?tab=incidents', 'Incidents'], ['/admin/incidents?tab=claims', 'Claims']]} /></>);
  if (tab === 'claims') {
    const { rows } = await list('claims', { limit: 200 });
    return (<>{head}<Card title="Claims"><Table<R> testId="claims" rows={rows} empty="No claims." cols={[{ key: 'claim_number', label: 'Claim' }, { key: 'path', label: 'Path', render: (r) => label(r.path) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'vehicle_name', label: 'Vehicle' }, { key: 'owner_name', label: 'Owner' },
      { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'damage_cost_cents', label: 'Damage', num: true, render: (r) => $(r.damage_cost_cents) }, { key: 'result_cents', label: 'Result', num: true, render: (r) => $(r.result_cents) },
      { key: 'act', label: 'Actions', render: (r) => <span className="ad-actions"><Act action="claim_status" payload={{ id: r.id }} label="Status" fields={[{ name: 'status', label: 'New status', type: 'select', required: true, options: ['submitted', 'accepted', 'denied', 'in_repair', 'repaired', 'settling', 'total_loss', 'settlement_received', 'distributed', 'closed', 'withdrawn'].map((k) => [k, label(k)] as [string, string]) }, { name: 'reason', label: 'Reason (required to deny)' }]} refresh={['/admin/incidents']} />
        {!r.settled_at && <Act action="claim_settle" payload={{ id: r.id }} label="Settle" confirm="Settle the claim: the result is split between the Owner and CarmaCars; a shareholder vehicle needs a second Admin." fields={[{ name: 'second_admin', label: 'Second Admin (user id, shareholder vehicles)' }]} refresh={['/admin/incidents']} />}</span> }]} /></Card></>);
  }
  const { rows } = await list('incidents', { limit: 200 });
  return (<>{head}<Card title="Incidents"><Table<R> testId="incidents" rows={rows} empty="No incidents." cols={[{ key: 'incident_number', label: 'Incident', render: (r) => <Link className="link" href={`/admin/incidents/${String(r.id)}`}>{String(r.incident_number)}</Link> }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) },
    { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'vehicle_name', label: 'Vehicle' }, { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'occurred_at', label: 'Happened', render: (r) => t(r.occurred_at) }, { key: 'drivable', label: 'Drivable' }]} /></Card></>);
}
