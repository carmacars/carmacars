import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { PastTrips, type PastTripRow } from '@/features/past-trips/PastTrips';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Close past trips', path: '/staff/past-trips', noindex: true, description: 'Bookings still open after their return time, closed at the booked times.' });

// Release 35 (migration 0910): Fleet closes the trips left open after their return time.
export default async function StaffPastTrips() {
  const { user, aal } = await vaPage('/staff/past-trips', ['fleet']);
  const v = await door<{ rows: PastTripRow[] }>(user.id, 'ops_read', 'past_trips', {}, aal);
  return (<>
    <PageHead title="Close past trips" purpose="Bookings confirmed or on rent whose return time has passed: close them so the deposit settles and the car is free." />
    <PastTrips rows={v.rows} base="/staff" refresh={['/staff/past-trips']} />
  </>);
}
