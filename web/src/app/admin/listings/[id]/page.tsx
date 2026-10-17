import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { withOriginalUrls } from '@/server/listing-photos';
import { SimilarityTable, type Flag } from '@/features/admin/Similarity';
import { Card } from '@/features/admin/ui';
import { ListingReview, type L, type Plates } from '@/features/admin/ListingReview';
import { Badge, PageHead } from '@/features/admin/ui';
import { door } from '@/server/door';
import { ListingCapture, type Capture } from '@/features/listing/ListingCapture';
import { ListingProgress, type Progress } from '@/features/listing/ListingProgress';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listing review', path: '/admin/listings', noindex: true, description: 'Review a listing draft and its photos.' });

export default async function Listing({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, user } = await page(`/admin/listings/${id}`);
  const l = await read<L | null>('listing', { id });
  if (!l) notFound();
  // possible duplicates of this car (migration 0040): an open flag that stops publishing is decided here first
  const flags = await read<Flag[]>('vehicle_similarity', { vehicle: l.vehicle_id }).catch(() => [] as Flag[]);
  const [cap, prog, plates] = await Promise.all([door<Capture>(user.id, 'ops_read', 'listing_capture', { intake: id }), door<Record<string, Progress>>(user.id, 'ops_read', 'listing_progress', { intake: id }),
    door<Plates>(user.id, 'ops_read', 'listing_plates', { vehicle: l.vehicle_id }).catch(() => null)]);
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/listings">Listings</Link> · <Link prefetch={false} className="link" href={`/admin/vehicles/${l.vehicle_id}`}>{l.vehicle.plate}</Link></>} title={<>{l.vehicle.name} <Badge s={l.state} /></>}>
        {['failed'].includes(l.state) && <Act action="listing_retry" payload={{ intake: l.id }} label="Retry" />}
        {l.listing?.status === 'published' && <Act action="listing_unlist" payload={{ vehicle: l.vehicle_id }} label="Unlist" variant="danger" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }, { name: 'to_path', label: 'Redirect to (empty: the model page or 410)', type: 'text' }]} />}
      </PageHead>
      {l.reason && <p className="pt-note small">{l.reason}</p>}
      {(((await door<Array<{ vehicle_id: string }>>(user.id, 'ops_read', 'vehicles_using_samples').catch(() => [])) ?? []).some((x) => x.vehicle_id === l.vehicle_id)) &&
        <p className="alert alert--warn" role="note" data-testid="listing-using-samples-note"><span className="alert__title">Using sample photos</span><span>No real photo is approved yet, so the listing shows sample photos, marked &quot;Sample photo&quot; on the site. You can publish it as it is: the photo problems below apply once real photos are added. The licence plate check does not apply to sample photos.</span></p>}
      {prog[id] && <ListingProgress initial={prog[id]} refresh={[`/admin/listings/${id}`]} />}
      {!['published', 'cancelled'].includes(l.state) && <ListingCapture initial={cap} refresh={[`/admin/listings/${id}`]} />}
      {flags.length > 0 && <Card title="Similar cars on file" testId="listing-similar"><SimilarityTable rows={flags} base="/admin" refresh={[`/admin/listings/${id}`]} showVehicle={false} /></Card>}
      <ListingReview l={await withOriginalUrls(l)} plates={plates} />
    </>
  );
}
