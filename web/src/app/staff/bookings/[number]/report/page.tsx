import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { HandoverReport } from '@/features/handover/HandoverReport';
import type { HandoverReportData } from '@/features/handover/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Photo report', path: '/staff', noindex: true, description: 'The check-out and check-in of a booking: times, readings, photos, damage and the return charges.' });

export default async function VaReport({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  const { user, aal, fn } = await vaPage(`/staff/bookings/${n}/report`);
  const r = await door<HandoverReportData | null>(user.id, 'ops_read', 'handover_report', { booking: n }, aal).catch(() => null);
  if (!r?.booking_id) notFound();
  const base = `/staff/bookings/${encodeURIComponent(n)}`;
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/staff">Queue</Link> · <Link prefetch={false} className="link" href={base}>{n}</Link></>} title="Photo report" purpose="The check-out and the check-in: times, kilometres, fuel, photos, damage and the return charges." />
    <HandoverReport r={r} staff canWaive={fn === 'finance' || fn === 'fleet'} refresh={[`${base}/report`, base]} />
  </>);
}
