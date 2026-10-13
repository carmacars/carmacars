import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { Badge, PageHead, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { ProgressCell, type Progress } from '@/features/listing/ListingProgress';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listings', path: '/va/listings', noindex: true, description: 'Listing intake and review.' });

type I = { id: string; vehicle_name: string; plate: string | null; state: string; reason: string | null; photos: number; listing_status: string | null; updated_at: string };

// Listing intake and review (05-va.md sections 3 and 4.3, 09-listing-pipeline.md): who may approve and
// publish follows listing_review_required_roles in the database.
export default async function VaListings() {
  const { read, fn, user, aal } = await vaPage('/va/listings', ['cs', 'fleet']);
  const rows = await read<I[]>('listings');
  const prog = rows.length ? await door<Record<string, Progress>>(user.id, 'ops_read', 'listing_progress', { intakes: rows.map((r) => r.id) }, aal) : {};
  return (
    <>
      <PageHead title="Listings" kicker={`${rows.filter((r) => r.state === 'needs_review').length} waiting for review`}>
        {fn === 'fleet' && <Act action="listing_start" label="Start a listing" variant="primary" fields={[{ name: 'plate', label: 'Plate', type: 'text' }, { name: 'vin', label: 'or VIN', type: 'text' }, { name: 'colour', label: 'Colour', type: 'text' }, { name: 'odometer_km', label: 'Odometer (km)', type: 'number' }]} go="/va/listings/{intake_id}" />}
      </PageHead>
      <Table<I> testId="listings" rows={rows} empty="No listings in progress." cols={[
        { key: 'vehicle_name', label: 'Vehicle', render: (r) => <Link prefetch={false} className="link" href={`/va/listings/${r.id}`}>{r.vehicle_name}</Link> }, { key: 'plate', label: 'Plate' },
        { key: 'state', label: 'State', render: (r) => <Badge s={r.state} /> }, { key: 'photos', label: 'Photos', num: true }, { key: 'progress', label: 'Pipeline', render: (r) => <ProgressCell p={prog[r.id]} /> },
        { key: 'listing_status', label: 'Listing', render: (r) => r.listing_status ? <Badge s={r.listing_status} /> : null }, { key: 'reason', label: 'Note', className: 'wrap' }, { key: 'updated_at', label: 'Updated', render: (r) => t(r.updated_at) }]} />
    </>
  );
}
