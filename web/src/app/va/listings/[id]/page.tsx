import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { withOriginalUrls } from '@/server/listing-photos';
import { SimilarityTable, type Flag } from '@/features/admin/Similarity';
import { Card } from '@/features/admin/ui';
import type { CarCopyData } from '@/features/seo/CarCopyPanel';
import { ListingReview, type Plates } from '@/features/admin/ListingReview';
import { Badge, PageHead } from '@/features/admin/ui';
import { door } from '@/server/door';
import { ListingCapture, type Capture } from '@/features/listing/ListingCapture';
import { ListingProgress, type Progress } from '@/features/listing/ListingProgress';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listing review', path: '/va/listings', noindex: true, description: 'Review a listing draft and its photos.' });

type L = Parameters<typeof ListingReview>[0]['l'];

export default async function VaListing({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, user, aal } = await vaPage(`/va/listings/${id}`, ['cs', 'fleet']);
  const l = await read<L | null>('listing', { id });
  if (!l) notFound();
  // possible duplicates of this car (migration 0040): an open flag that stops publishing is decided here first
  const flags = await read<Flag[]>('vehicle_similarity', { vehicle: l.vehicle_id }).catch(() => [] as Flag[]);
  const [cap, prog, plates] = await Promise.all([door<Capture>(user.id, 'ops_read', 'listing_capture', { intake: id }, aal), door<Record<string, Progress>>(user.id, 'ops_read', 'listing_progress', { intake: id }, aal),
    door<Plates>(user.id, 'ops_read', 'listing_plates', { vehicle: l.vehicle_id }, aal).catch(() => null)]);
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/va/listings">Listings</Link>} title={<>{l.vehicle.name} <Badge s={l.state} /></>} />
      {l.reason && <p className="pt-note small">{l.reason}</p>}
      {prog[id] && <ListingProgress initial={prog[id]} refresh={[`/va/listings/${id}`]} />}
      {!['published', 'cancelled'].includes(l.state) && <ListingCapture initial={cap} refresh={[`/va/listings/${id}`]} />}
      {flags.length > 0 && <Card title="Similar cars on file" testId="listing-similar"><SimilarityTable rows={flags} base="/va" refresh={[`/va/listings/${id}`]} showVehicle={false} /></Card>}
      <ListingReview l={await withOriginalUrls(l)} plates={plates} copy={await door<CarCopyData>(user.id, 'ops_read', 'car_copy', { vehicle: l.vehicle_id }, aal).catch(() => null)} />
    </>
  );
}
