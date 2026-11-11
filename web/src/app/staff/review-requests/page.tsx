import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ReviewsDashboard, type Overview } from '@/features/reviews/ReviewsDashboard';
import { OutsideReviews, type OutsideRow } from '@/features/reviews/OutsideReviews';
import { getFleet } from '@/lib/site';

// Customer service's review requests (migration 0146): the numbers, the "Review requests on hold" list (Send anyway, Do
// not ask) and the Google reviews to match to renters. Sales sees it too (no matching).
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Review requests', path: '/staff/review-requests', noindex: true, description: 'Review requests on hold and Google reviews to match.' });

export default async function VaReviewRequests() {
  const { user, fn, aal } = await vaPage('/staff/review-requests', ['cs', 'sales']);
  const [o, outside, fleet] = await Promise.all([door<Overview>(user.id, 'ops_read', 'review_overview', { days: 30, _va: fn }, aal).catch(() => null),
    door<OutsideRow[]>(user.id, 'ops_read', 'outside_reviews', { _va: fn }, aal).catch(() => []), getFleet().catch(() => [])]);
  return (
    <>
      <PageHead title="Review requests" purpose="Add customer reviews received elsewhere, bookings whose review request waits for open charges, and Google reviews to match to renters." />
      <OutsideReviews rows={outside} cars={fleet.filter((c) => !c.is_sample).map((c) => ({ id: c.vehicle_id, name: [c.year, c.make, c.model, c.trim].filter(Boolean).join(' ') }))} admin={false} refresh={['/staff/review-requests']} />
      {o ? <ReviewsDashboard o={o} base="/staff/review-requests" bookingBase="/staff/bookings" admin={false} canMatch={fn === 'cs'} /> : <p>Not available.</p>}
    </>
  );
}
