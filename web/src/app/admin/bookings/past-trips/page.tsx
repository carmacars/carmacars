import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { EndedTrips } from '@/features/past-trips/EndedTrips';
import type { EndedRow } from '@/features/past-trips/ended';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Close ended trips', path: '/admin/bookings/past-trips', noindex: true, description: 'Bookings past their return time and not closed: marked and closed, deposits decided.' });

// Release 35 (0910, 1063): ended trips never left open.
export default async function AdminEndedTrips() {
  const { user } = await page('/admin/bookings/past-trips');
  const v = await door<{ admin: boolean; can_no_show: boolean; rows: EndedRow[] }>(user.id, 'ops_read', 'ended_trips', {});
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link>} title="Close ended trips" purpose="Bookings past their return time that are not closed: never picked up in the system, on rent after the return, or returned and never closed." />
    <EndedTrips rows={v.rows} base="/admin" admin={v.admin} canNoShow={v.can_no_show} />
  </>);
}
