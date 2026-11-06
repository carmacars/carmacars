import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { Badge, PageHead, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { ProgressCell, type Progress } from '@/features/listing/ListingProgress';
import { CarCell } from '@/features/admin/revamp/CarCell';
import { carPhotos } from '@/server/car-photos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listings', path: '/staff/listings', noindex: true, description: 'Listing intake and review.' });

type I = { id: string; vehicle_id?: string; vehicle_name: string; plate: string | null; state: string; reason: string | null; photos: number; listing_status: string | null; updated_at: string };

// Listing intake and review (05-va.md sections 3 and 4.3, 09-listing-pipeline.md): who may approve and
// publish follows listing_review_required_roles in the database.
export default async function VaListings() {
  const { read, fn, user, aal } = await vaPage('/staff/listings', ['cs', 'fleet']);
  const rows = await read<I[]>('listings');
  const photos = await carPhotos(rows);
  const prog = rows.length ? await door<Record<string, Progress>>(user.id, 'ops_read', 'listing_progress', { intakes: rows.map((r) => r.id) }, aal) : {};
  return (
    <>
      <PageHead title="Listings" kicker={`${rows.filter((r) => r.state === 'needs_review').length} waiting for review`}>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/owners/add-car" data-testid="add-car-link">Add a car for an owner</Link>
        {fn === 'fleet' && <Act action="listing_start" label="Start a listing" variant="primary" fields={[{ name: 'plate', label: 'Plate', type: 'text' }, { name: 'vin', label: 'or VIN', type: 'vin' }, { name: 'colour', label: 'Colour', type: 'text' }, { name: 'odometer_km', label: 'Odometer (km)', type: 'number' }]} go="/staff/listings/{intake_id}" />}
      </PageHead>
      <Table<I> testId="listings" rows={rows} empty="No listings in progress." cols={[
        { key: 'vehicle_name', label: 'Vehicle', render: (r) => <Link prefetch={false} className="link" href={`/staff/listings/${r.id}`}><CarCell name={r.vehicle_name} photo={photos[String(r.vehicle_id)]} sub={r.plate} /></Link> },
        { key: 'state', label: 'State', render: (r) => <Badge s={r.state} /> }, { key: 'photos', label: 'Photos', num: true }, { key: 'progress', label: 'Work done', render: (r) => <ProgressCell p={prog[r.id]} /> },
        { key: 'listing_status', label: 'Listing', render: (r) => r.listing_status ? <Badge s={r.listing_status} /> : null }, { key: 'reason', label: 'Note', className: 'wrap' }, { key: 'updated_at', label: 'Updated', render: (r) => t(r.updated_at) }]} />
    </>
  );
}
