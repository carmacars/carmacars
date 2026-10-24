import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { OfferComposer } from '@/features/offers/OfferComposer';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Send an offer', path: '/admin/offers/new', noindex: true, description: 'Send an offer to a customer without waiting for a request.' });

// Admin > Bookings > Send an offer (migration 0129): no request needed. The same request and offer the website makes.
export default async function NewOffer({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await page('/admin/offers/new');
  const sp = await searchParams;
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link>} title="Send an offer" />
    <p className="small muted" style={{ maxWidth: '52rem' }}>For a customer on the phone, by text or in person: no request needed. The renter gets the offer link, approves, signs and pays (or you record the payment); then it is on the calendar. For a rental that is already agreed and paid, use <Link prefetch={false} className="link" href="/admin/bookings/new">Add a rental</Link>.</p>
    <OfferComposer base="/admin" initialCar={sp.car ?? null} />
  </>);
}
