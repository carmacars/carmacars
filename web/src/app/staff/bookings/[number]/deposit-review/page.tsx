import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ReviewPage } from '@/features/deposit-review/ReviewPage';
import type { ReviewView } from '@/features/deposit-review/model';
import type { HandoverReportData } from '@/features/handover/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Deposit review', path: '/staff', noindex: true, description: 'Fleet checks the return, Finance double-checks, then the deposit is billed or released.' });

// The deposit review of one returned booking for Fleet and Finance (release 35 part RR, 1010); the Admin has the same page.
export default async function VaDepositReview({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  const { user, aal, fn } = await vaPage(`/staff/bookings/${n}/deposit-review`, ['fleet', 'finance']);
  const [v, r] = await Promise.all([door<ReviewView | null>(user.id, 'ops_read', 'deposit_review', { booking: n, _va: fn }, aal).catch(() => null),
    door<HandoverReportData | null>(user.id, 'ops_read', 'handover_report', { booking: n }, aal).catch(() => null)]);
  if (!v?.booking_id) notFound();
  const base = `/staff/bookings/${encodeURIComponent(n)}`;
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/staff/deposit-reviews">Deposit reviews</Link> · <Link prefetch={false} className="link" href={base}>{n}</Link></>} title="Deposit review"
      purpose="Fleet checks each item against the pickup, then Finance double-checks it and checks the tolls and every ticket place. Then bill what is owed or release the deposit." />
    <ReviewPage d={v} report={r?.booking_id ? r : null} base={base} tollsHref="/staff/tolls" refresh={[`${base}/deposit-review`, base, '/staff/deposit-reviews']} />
  </>);
}
