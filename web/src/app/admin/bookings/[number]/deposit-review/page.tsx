import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ReviewPage } from '@/features/deposit-review/ReviewPage';
import type { ReviewView } from '@/features/deposit-review/model';
import type { HandoverReportData } from '@/features/handover/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Deposit review', path: '/admin/bookings', noindex: true, description: 'Fleet checks the return, Finance double-checks, then the deposit is billed or released.' });

// The deposit review of one returned booking (release 35 part RR, 1010): an Admin signs either side and releases past it
// on Money with the reason. Fleet and Finance have the same page in the staff portal.
export default async function AdminDepositReview({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  const { user } = await page(`/admin/bookings/${n}/deposit-review`);
  const [v, r] = await Promise.all([door<ReviewView | null>(user.id, 'ops_read', 'deposit_review', { booking: n }).catch(() => null),
    door<HandoverReportData | null>(user.id, 'ops_read', 'handover_report', { booking: n }).catch(() => null)]);
  if (!v?.booking_id) notFound();
  const base = `/admin/bookings/${encodeURIComponent(n)}`;
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/deposit-reviews">Deposit reviews</Link> · <Link prefetch={false} className="link" href={base}>{n}</Link></>} title="Deposit review"
      purpose="Fleet checks each item against the pickup, then Finance double-checks it and checks the tolls and every ticket place. Then bill what is owed or release the deposit." />
    <ReviewPage d={v} report={r?.booking_id ? r : null} base={base} tollsHref="/admin/tolls" refresh={[`${base}/deposit-review`, base, '/admin/deposit-reviews']} />
  </>);
}
