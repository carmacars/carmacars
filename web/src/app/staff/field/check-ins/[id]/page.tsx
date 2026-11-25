import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { requireStaff, sessionAal, door } from '@/server/door';
import { CheckinVisitView } from '@/features/checkins/VisitView';
import type { VisitRead } from '@/features/checkins/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-in visit', path: '/staff/field/check-ins', noindex: true, description: 'One monthly check-in visit and its checklist.' });

export default async function FieldCheckin({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { user } = await requireStaff('field', `/staff/field/check-ins/${id}`);
  const d = await door<VisitRead>(user.id, 'field_read', 'checkin_visit', { id }, await sessionAal());
  return (
    <>
      <p><Link prefetch={false} className="link" href="/staff/field/check-ins">Check-in visits</Link></p>
      <header className="fd-home"><h1 className="fd-home__h">Check-in visit</h1><p className="fd-home__sub">{d.booking.booking_number}</p></header>
      <CheckinVisitView d={d} base="/staff/field" bookingHref={null} />
    </>
  );
}
