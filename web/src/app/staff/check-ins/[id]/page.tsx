import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { CheckinVisitView } from '@/features/checkins/VisitView';
import type { VisitRead } from '@/features/checkins/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-in visit', path: '/staff/check-ins', noindex: true, description: 'One monthly check-in visit and its checklist.' });

export default async function StaffCheckin({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { user, aal } = await vaPage(`/staff/check-ins/${id}`, ['fleet', 'cs']);
  const d = await door<VisitRead>(user.id, 'ops_read', 'checkin_visit', { id }, aal);
  return (<><p><Link prefetch={false} className="link" href="/staff/check-ins">Check-in visits</Link></p><PageHead title="Check-in visit" kicker={d.booking.booking_number} /><CheckinVisitView d={d} base="/staff" bookingHref={`/staff/bookings/${encodeURIComponent(d.booking.booking_number)}`} /></>);
}
