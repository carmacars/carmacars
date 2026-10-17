import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, PageHead, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { ProgressCell, type Progress } from '@/features/listing/ListingProgress';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listings', path: '/admin/listings', noindex: true, description: 'Listing intake and review.' });

type I = { id: string; vehicle_id: string; vehicle_name: string; plate: string | null; state: string; reason: string | null; started_role: string; started_by_name: string | null; photos: number; listing_status: string | null; updated_at: string; review_required: boolean };

// The listing pipeline's queue (09-listing-pipeline.md): drafts waiting for review first, then failures.
export default async function Listings() {
  const { read, user } = await page('/admin/listings');
  const rows = await read<I[]>('listings');
  const prog = rows.length ? await door<Record<string, Progress>>(user.id, 'ops_read', 'listing_progress', { intakes: rows.map((r) => r.id) }) : {};
  const samples = new Set(((await door<Array<{ vehicle_id: string }>>(user.id, 'ops_read', 'vehicles_using_samples').catch(() => [])) ?? []).map((x) => x.vehicle_id));
  return (
    <>
      <PageHead title="Listings" kicker={`${rows.filter((r) => r.state === 'needs_review').length} waiting for review`}>
        <Act action="listing_start" label="Start a listing" variant="primary" fields={[{ name: 'plate', label: 'Plate', type: 'text' }, { name: 'vin', label: 'or VIN', type: 'text' }, { name: 'colour', label: 'Colour', type: 'text' }, { name: 'odometer_km', label: 'Odometer (km)', type: 'number' }]} go="/admin/listings/{intake_id}" />
      </PageHead>
      <Table<I> testId="listings" caption="Listing intakes" rows={rows} empty="No listings in progress. Press Start a listing to list a car: real photos are optional, sample photos are shown until they are added." cols={[
        { key: 'vehicle_name', label: 'Vehicle', render: (r) => <Link prefetch={false} className="link" href={`/admin/listings/${r.id}`}>{r.vehicle_name}</Link> },
        { key: 'plate', label: 'Plate' }, { key: 'state', label: 'State', render: (r) => <Badge s={r.state} /> },
        { key: 'photos', label: 'Photos', render: (r) => samples.has(r.vehicle_id) ? <span data-testid="listing-using-samples">{r.photos} <Badge s="needs_review">Using sample photos</Badge></span> : String(r.photos) }, { key: 'progress', label: 'Pipeline', render: (r) => <ProgressCell p={prog[r.id]} /> }, { key: 'listing_status', label: 'Listing', render: (r) => r.listing_status ? <Badge s={r.listing_status} /> : null },
        { key: 'started', label: 'Started by', render: (r) => `${r.started_by_name ?? ''} (${r.started_role})` }, { key: 'reason', label: 'Note', className: 'wrap' },
        { key: 'updated_at', label: 'Updated', render: (r) => t(r.updated_at) }
      ]} />
    </>
  );
}
