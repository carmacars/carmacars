import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead, bookingHref } from '@/features/admin/ui';
import { CheckinVisitView } from '@/features/checkins/VisitView';
import type { VisitRead } from '@/features/checkins/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-in visit', path: '/admin/check-ins', noindex: true, description: 'One monthly check-in visit and its checklist.' });

export default async function AdminCheckin({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { user } = await page(`/admin/check-ins/${id}`);
  const d = await door<VisitRead>(user.id, 'ops_read', 'checkin_visit', { id });
  return (<><p><Link prefetch={false} className="link" href="/admin/check-ins">Check-in visits</Link></p><PageHead title="Check-in visit" kicker={d.booking.booking_number} /><CheckinVisitView d={d} base="/admin" bookingHref={bookingHref(d.booking.booking_number)} /></>);
}
