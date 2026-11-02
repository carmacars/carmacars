import Link from '@/components/Link';
import type { AdminPage } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, PageHead, Table, t, label } from '@/features/admin/ui';
import { CarCell } from '@/features/admin/revamp/CarCell';
import { carPhotos } from '@/server/car-photos';

type R = Record<string, unknown>;

// Bookings > Damage and claims > Incidents and Claims (r27: tabs of Damage and claims, /admin/incidents redirects; an
// incident keeps its own page).
export async function Incidents({ ctx: { list }, tab }: { ctx: AdminPage; tab: 'incidents' | 'claims' }) {
  const vehicles = await list<{ id: string; make: string; model: string; plate: string | null }>('vehicles', { order: 'make', asc: true, limit: 500 });
  const head = (<><PageHead title={tab === 'claims' ? 'Claims' : 'Incidents'} purpose={tab === 'claims' ? 'Claims with an insurer, opened from an incident: status, damage, result and the settlement.' : 'Accidents, thefts, breakdowns and damage reported during a rental. Open one for its claim, photos and costs.'}><Act action="incident_open" label="Open an incident" variant="primary" go="/admin/incidents/{id}" fields={[
    { name: 'kind', label: 'Kind', type: 'select', required: true, options: ['accident', 'damage_found_later', 'damage_at_return', 'breakdown', 'theft', 'vandalism', 'late_return', 'non_return', 'tracker_tampering', 'impound', 'other'].map((k) => [k, label(k)] as [string, string]) },
    { name: 'vehicle', label: 'Vehicle', type: 'select', required: true, options: vehicles.rows.map((v) => [v.id, `${v.make} ${v.model} ${v.plate ?? ''}`]) },
    { name: 'details', label: 'Details (what, where, when, drivable)', type: 'json', value: { description: '', place: '', drivable: true } }]} /></PageHead>
</>);
  if (tab === 'claims') {
    const { rows } = await list('claims', { limit: 200 });
    const photos = await carPhotos(rows);
    return (<>{head}<Card title="Claims"><Table<R> testId="claims" rows={rows} empty="No claims. A claim is opened from an incident when the insurer is involved." cols={[{ key: 'claim_number', label: 'Claim' }, { key: 'path', label: 'Path', render: (r) => label(r.path) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'vehicle_name', label: 'Vehicle', render: (r) => <CarCell name={r.vehicle_name} photo={photos[String(r.vehicle_id)]} /> }, { key: 'owner_name', label: 'Owner' },
      { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'damage_cost_cents', label: 'Damage', num: true, render: (r) => $(r.damage_cost_cents) }, { key: 'result_cents', label: 'Result', num: true, render: (r) => $(r.result_cents) },
      { key: 'act', label: 'Actions', render: (r) => <span className="ad-actions"><Act action="claim_status" payload={{ id: r.id }} label="Status" fields={[{ name: 'status', label: 'New status', type: 'select', required: true, options: ['submitted', 'accepted', 'denied', 'in_repair', 'repaired', 'settling', 'total_loss', 'settlement_received', 'distributed', 'closed', 'withdrawn'].map((k) => [k, label(k)] as [string, string]) }, { name: 'reason', label: 'Reason (required to deny)' }]} refresh={['/admin/damages']} />
        {!r.settled_at && <Act action="claim_settle" payload={{ id: r.id }} label="Settle" confirm="Settle the claim: the result is split between the Owner and CarmaCars; a shareholder vehicle needs a second Admin." fields={[{ name: 'second_admin', label: 'Second Admin (user id, shareholder vehicles)' }]} refresh={['/admin/damages']} />}</span> }]} /></Card></>);
  }
  const { rows } = await list('incidents', { limit: 200 });
  const photos = await carPhotos(rows);
  return (<>{head}<Card title="Incidents"><Table<R> testId="incidents" rows={rows} empty="No incidents. Report one from the booking when a renter tells you about an accident, theft or damage." cols={[{ key: 'incident_number', label: 'Incident', render: (r) => <Link prefetch={false} className="link" href={`/admin/incidents/${String(r.id)}`}>{String(r.incident_number)}</Link> }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) },
    { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'vehicle_name', label: 'Vehicle', render: (r) => <CarCell name={r.vehicle_name} photo={photos[String(r.vehicle_id)]} /> }, { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'occurred_at', label: 'Happened', render: (r) => t(r.occurred_at) }, { key: 'drivable', label: 'Drivable' }]} /></Card></>);
}
