import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { EndedTrips } from '@/features/past-trips/EndedTrips';
import type { EndedRow } from '@/features/past-trips/ended';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Close ended trips', path: '/staff/past-trips', noindex: true, description: 'Bookings past their return time and not closed: marked and closed, deposits decided.' });

// Release 35 (0910, 1063): Fleet and Finance close the trips left open after their return time.
export default async function StaffEndedTrips() {
  const { user, aal } = await vaPage('/staff/past-trips', ['fleet', 'finance']);
  const v = await door<{ admin: boolean; can_no_show: boolean; rows: EndedRow[] }>(user.id, 'ops_read', 'ended_trips', {}, aal);
  return (<>
    <PageHead title="Close ended trips" purpose="Bookings past their return time that are not closed: never picked up in the system, on rent after the return, or returned and never closed." />
    <EndedTrips rows={v.rows} base="/staff" admin={v.admin} canNoShow={v.can_no_show} />
  </>);
}
