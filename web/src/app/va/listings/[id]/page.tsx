import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { ListingReview } from '@/features/admin/ListingReview';
import { Badge, PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listing review', path: '/va/listings', noindex: true, description: 'Review a listing draft and its photos.' });

type L = Parameters<typeof ListingReview>[0]['l'];

export default async function VaListing({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await vaPage(`/va/listings/${id}`, ['cs', 'fleet']);
  const l = await read<L | null>('listing', { id });
  if (!l) notFound();
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/va/listings">Listings</Link>} title={<>{l.vehicle.name} <Badge s={l.state} /></>} />
      {l.reason && <p className="pt-note small">{l.reason}</p>}
      <ListingReview l={l} />
    </>
  );
}
