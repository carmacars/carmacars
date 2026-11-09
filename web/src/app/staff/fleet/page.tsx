import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { redirect } from 'next/navigation';
import { door, rolesOf } from '@/server/door';
import { currentUser } from '@/server/portal/data';
import { FieldJobsBoard, type Board } from '@/features/va/FieldJobs';
import type { CalVehicle } from '@/features/va/carboard';
import { requestNow } from '@/features/va/lanes';
import { carPhotos } from '@/server/car-photos';
import Link from 'next/link';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field jobs', path: '/staff/fleet', noindex: true, description: 'Field job scheduling and assignment.' });

// Fleet Operations (05-va.md section 3): every confirmed booking gets its handover and return jobs by itself, at the booking's
// times and place, given to the least busy field staff member who passed the academy and holds a shift that day (0880).
// The board is the one shared with the Admin's page (features/va/FieldJobs.tsx).
export default async function Fleet() {
  // an Admin account is only an Admin (0882): it opens the same board in the Admin portal, with every action
  const me = await currentUser();
  if (me && (await rolesOf(me.id)).admin) redirect('/admin/field-jobs');
  const { user, aal, read } = await vaPage('/staff/fleet', ['fleet']);
  const now = requestNow();
  const [b, cal, past] = await Promise.all([door<Board>(user.id, 'ops_read', 'field_board', {}, aal),
    read<{ vehicles: CalVehicle[] }>('calendar', { from: new Date(now - 86_400_000).toISOString(), to: new Date(now + 2 * 86_400_000).toISOString() }).then((c) => c.vehicles).catch(() => [] as CalVehicle[]),
    // 0910: trips still open after their return time
    door<{ rows: unknown[] }>(user.id, 'ops_read', 'past_trips', {}, aal).then((x) => x.rows.length).catch(() => 0)]);
  const photos = await carPhotos([...b.unscheduled, ...b.jobs]);
  return (
    <>
      {past > 0 && <p className="alert alert--warn" role="status" data-testid="past-trips-banner"><span>{past} {past === 1 ? 'trip is' : 'trips are'} still open after the return time. <Link prefetch={false} className="link" href="/staff/past-trips">Close past trips</Link></span></p>}
      <FieldJobsBoard b={b} cal={cal} now={now} photos={photos} base="/staff" />
    </>
  );
}
