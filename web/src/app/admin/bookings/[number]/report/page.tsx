import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { HandoverReport } from '@/features/handover/HandoverReport';
import type { HandoverReportData } from '@/features/handover/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Photo report', path: '/admin/bookings', noindex: true, description: 'The check-out and check-in of a booking: times, readings, photos, damage and the return charges.' });

export default async function AdminReport({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  const { user } = await page(`/admin/bookings/${n}/report`);
  const r = await door<HandoverReportData | null>(user.id, 'ops_read', 'handover_report', { booking: n }).catch(() => null);
  if (!r?.booking_id) notFound();
  const base = `/admin/bookings/${encodeURIComponent(n)}`;
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link> · <Link prefetch={false} className="link" href={base}>{n}</Link></>} title="Photo report" purpose="The check-out and the check-in: times, kilometres, fuel, photos, damage and the return charges." />
    <HandoverReport r={r} staff canWaive canCorrect refresh={[`${base}/report`, base]} />
  </>);
}
