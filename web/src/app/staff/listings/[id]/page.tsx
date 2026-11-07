import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { ListingPage } from '@/features/listing-page/ListingPage';
import { staffCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listing review', path: '/staff/listings', noindex: true, description: 'Review a listing draft and its photos.' });

// r31: the same page as the Admin's (features/listing-page), read through the staff door (customer service and Fleet).
export default async function VaListing({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  return <ListingPage ctx={await staffCtx(`/staff/listings/${id}`, ['cs', 'fleet'])} id={id} />;
}
