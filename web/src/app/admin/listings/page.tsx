import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { ProgressCell, type Progress } from '@/features/listing/ListingProgress';
import { NeedCell, type NeedRow } from '@/features/listing/PhotosNeeded';
import { CarCell } from '@/features/admin/revamp/CarCell';
import { carPhotos } from '@/server/car-photos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listings', path: '/admin/listings', noindex: true, description: 'Listing intake and review.' });

type I = { id: string; vehicle_id: string; vehicle_name: string; plate: string | null; state: string; reason: string | null; started_role: string; started_by_name: string | null; photos: number; listing_status: string | null; updated_at: string; review_required: boolean };

// The listing pipeline's queue (09-listing-pipeline.md): drafts waiting for review first, then failures.
export default async function Listings() {
  const { read, user } = await page('/admin/listings');
  const rows = await read<I[]>('listings');
  const photos = await carPhotos(rows);
  const prog = rows.length ? await door<Record<string, Progress>>(user.id, 'ops_read', 'listing_progress', { intakes: rows.map((r) => r.id) }) : {};
  // R23 (0236): the real cars still on sample photos, with their handover photos
  const need = await door<{ required: number; cars: NeedRow[] }>(user.id, 'ops_read', 'photos_needed').catch(() => ({ required: 0, cars: [] as NeedRow[] }));
  const samples = new Set(((await door<Array<{ vehicle_id: string }>>(user.id, 'ops_read', 'vehicles_using_samples').catch(() => [])) ?? []).map((x) => x.vehicle_id));
  return (
    <>
      <PageHead title="Listings" kicker={`${rows.filter((r) => r.state === 'needs_review').length} waiting for review`}>
        <Act action="listing_start" label="Start a listing" variant="primary" fields={[{ name: 'plate', label: 'Plate', type: 'text' }, { name: 'vin', label: 'or VIN', type: 'text' }, { name: 'colour', label: 'Colour', type: 'text' }, { name: 'odometer_km', label: 'Odometer (km)', type: 'number' }]} go="/admin/listings/{intake_id}" />
      </PageHead>
      <Table<I> testId="listings" caption="Listing intakes" rows={rows} empty="No listings in progress. Press Start a listing to list a car: real photos are optional, sample photos are shown until they are added." cols={[
        { key: 'vehicle_name', label: 'Vehicle', render: (r) => <Link prefetch={false} className="link" href={`/admin/listings/${r.id}`}><CarCell name={r.vehicle_name} photo={photos[String(r.vehicle_id)]} sub={r.plate} /></Link> },
        { key: 'plate', label: 'Plate' }, { key: 'state', label: 'State', render: (r) => <Badge s={r.state} /> },
        { key: 'photos', label: 'Photos', render: (r) => samples.has(r.vehicle_id) ? <span data-testid="listing-using-samples">{r.photos} <Badge s="needs_review">Using sample photos</Badge></span> : String(r.photos) }, { key: 'progress', label: 'Pipeline', render: (r) => <ProgressCell p={prog[r.id]} /> }, { key: 'listing_status', label: 'Listing', render: (r) => r.listing_status ? <Badge s={r.listing_status} /> : null },
        { key: 'started', label: 'Started by', render: (r) => `${r.started_by_name ?? ''} (${r.started_role})` }, { key: 'reason', label: 'Note', className: 'wrap' },
        { key: 'updated_at', label: 'Updated', render: (r) => t(r.updated_at) }
      ]} />
      <Card title={`Cars on sample photos (${need.cars.length})`} testId="photos-needed">
        <p className="small">Each real car whose page still shows sample photos. Where a handover photographed the car (the check-out and check-in photos), use them: the studio editor puts the car on the CarmaCars backdrop and the listing waits for your review. The others need photos at their next handover.</p>
        <Table<NeedRow & Record<string, unknown>> rows={need.cars as Array<NeedRow & Record<string, unknown>>} rowKey={(r) => r.vehicle_id} empty="Every real car has its own photos."
          cols={[{ key: 'name', label: 'Car', render: (r) => <Link prefetch={false} className="link" href={`/admin/vehicles/${r.vehicle_id}`}>{r.name}{r.fleet_number ? ` (${r.fleet_number})` : ''}</Link> },
            { key: 'status', label: 'Status', render: (r) => <Badge s={r.status} /> },
            { key: 'handover_at', label: 'Newest handover photos', render: (r) => (r.handover_at ? `${t(r.handover_at)}: ${r.handover_shots} shots` : 'None') },
            { key: 'act', label: '', render: (r) => <NeedCell r={r} /> }]} />
      </Card>
    </>
  );
}
