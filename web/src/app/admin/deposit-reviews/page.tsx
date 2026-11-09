import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { ReviewList } from '@/features/deposit-review/ReviewList';
import type { ReviewList as Data } from '@/features/deposit-review/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Deposit reviews', path: '/admin/deposit-reviews', noindex: true, description: 'Returns to check before their deposits are released, and the tolls and tickets sweep.' });

const VIEWS = ['open', 'fleet', 'finance', 'sweep', 'done'];

// Every deposit review (release 35 part RR, 1010), the same page as Fleet's and Finance's.
export default async function AdminDepositReviews({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/deposit-reviews'), searchParams]);
  const view = VIEWS.includes(sp.view ?? '') ? sp.view! : 'open';
  const v = await door<Data>(user.id, 'ops_read', 'deposit_reviews', { view });
  return <ReviewList d={v} base="/admin/deposit-reviews" bookingBase="/admin/bookings" />;
}
