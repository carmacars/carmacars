import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { OfferComposer } from '@/features/offers/OfferComposer';
import { door } from '@/server/door';
import type { OwnerDefaults } from '@/features/supply/OwnerChoice';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Send an offer', path: '/va/offers/new', noindex: true, description: 'Send an offer to a customer without waiting for a request.' });

// Customer service and sales send an offer without a request (migration 0129): the rate sheet or a price typed with its
// reason, "I sourced this client" or "Entered for CarmaCars", open for 48 hours at most.
export default async function VaNewOffer({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const { user, aal } = await vaPage('/va/offers/new', ['cs', 'sales']);
  const owner = await door<OwnerDefaults>(user.id, 'ops_read', 'owner_visibility_defaults', {}, aal).catch(() => null);
  const sp = await searchParams;
  return (<>
    <PageHead title="Send an offer" />
    <p className="small muted" style={{ maxWidth: '52rem' }}>For a customer on the phone, by text or in person: no request needed. Already agreed and paid? Use <Link prefetch={false} className="link" href="/va/bookings/new">Add a rental</Link>.</p>
    <OfferComposer base="/va" initialCar={sp.car ?? null} owner={owner} />
  </>);
}
