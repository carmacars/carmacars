import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { ListingPage } from '@/features/listing-page/ListingPage';
import { adminCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Listing review', path: '/admin/listings', noindex: true, description: 'Review a listing draft and its photos.' });

// r31: the same page as staff's (features/listing-page), read through the Admin's door.
export default async function Listing({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  return <ListingPage ctx={await adminCtx(`/admin/listings/${id}`)} id={id} />;
}
