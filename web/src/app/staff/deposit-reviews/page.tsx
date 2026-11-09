import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { ReviewList } from '@/features/deposit-review/ReviewList';
import type { ReviewList as Data } from '@/features/deposit-review/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Deposit reviews', path: '/staff/deposit-reviews', noindex: true, description: 'Returns to check before their deposits are released, and the tolls and tickets sweep.' });

const VIEWS = ['open', 'fleet', 'finance', 'sweep', 'done'];

// Fleet and Finance (release 35 part RR, 1010): Fleet opens on its returns to check, Finance on what it double-checks; the
// sweep lists the plates with every link. The Admin has the same page.
export default async function VaDepositReviews({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal, fn }, sp] = await Promise.all([vaPage('/staff/deposit-reviews', ['fleet', 'finance']), searchParams]);
  const view = VIEWS.includes(sp.view ?? '') ? sp.view! : fn === 'fleet' ? 'fleet' : 'finance';
  const v = await door<Data>(user.id, 'ops_read', 'deposit_reviews', { view, _va: fn }, aal);
  return <ReviewList d={v} base="/staff/deposit-reviews" bookingBase="/staff/bookings" />;
}
