import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { PastTrips, type PastTripRow } from '@/features/past-trips/PastTrips';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Close past trips', path: '/admin/bookings/past-trips', noindex: true, description: 'Bookings still open after their return time, closed at the booked times.' });

// Release 35 (migration 0910): past trips never left open.
export default async function AdminPastTrips() {
  const { user } = await page('/admin/bookings/past-trips');
  const v = await door<{ rows: PastTripRow[] }>(user.id, 'ops_read', 'past_trips', {});
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link>} title="Close past trips" purpose="Bookings confirmed or on rent whose return time has passed: close them so the deposit settles and the car is free." />
    <PastTrips rows={v.rows} base="/admin" refresh={['/admin/bookings/past-trips', '/admin/bookings']} />
  </>);
}
