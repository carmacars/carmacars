import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { withOriginalUrls } from '@/server/listing-photos';
import { ListingReview, type L } from '@/features/admin/ListingReview';
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
  const [cap, prog] = await Promise.all([door<Capture>(user.id, 'ops_read', 'listing_capture', { intake: id }), door<Record<string, Progress>>(user.id, 'ops_read', 'listing_progress', { intake: id })]);
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/listings">Listings</Link> · <Link prefetch={false} className="link" href={`/admin/vehicles/${l.vehicle_id}`}>{l.vehicle.plate}</Link></>} title={<>{l.vehicle.name} <Badge s={l.state} /></>}>
        {['failed'].includes(l.state) && <Act action="listing_retry" payload={{ intake: l.id }} label="Retry" />}
        {l.listing?.status === 'published' && <Act action="listing_unlist" payload={{ vehicle: l.vehicle_id }} label="Unlist" variant="danger" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }, { name: 'to_path', label: 'Redirect to (empty: the model page or 410)', type: 'text' }]} />}
      </PageHead>
      {l.reason && <p className="pt-note small">{l.reason}</p>}
      {prog[id] && <ListingProgress initial={prog[id]} refresh={[`/admin/listings/${id}`]} />}
      {!['published', 'cancelled'].includes(l.state) && <ListingCapture initial={cap} refresh={[`/admin/listings/${id}`]} />}
      <ListingReview l={await withOriginalUrls(l)} />
    </>
  );
}
