import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ReviewsDashboard, type Overview } from '@/features/reviews/ReviewsDashboard';

// Customer service's review requests (migration 0138): the numbers, the "Review requests on hold" list (Send anyway, Do
// not ask) and the Google reviews to match to renters. Sales sees it too (no matching).
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Review requests', path: '/va/review-requests', noindex: true, description: 'Review requests on hold and Google reviews to match.' });

export default async function VaReviewRequests() {
  const { user, fn, aal } = await vaPage('/va/review-requests', ['cs', 'sales']);
  const o = await door<Overview>(user.id, 'ops_read', 'review_overview', { days: 30, _va: fn }, aal).catch(() => null);
  return (
    <>
      <PageHead title="Review requests" purpose="Bookings whose review request waits for open charges, and Google reviews to match to renters." />
      {o ? <ReviewsDashboard o={o} base="/va/review-requests" bookingBase="/va/bookings" admin={false} canMatch={fn === 'cs'} /> : <p>Not available.</p>}
    </>
  );
}
