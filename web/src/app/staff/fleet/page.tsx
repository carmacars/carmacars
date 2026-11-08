import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { FieldJobsBoard, type Board } from '@/features/va/FieldJobs';
import type { CalVehicle } from '@/features/va/carboard';
import { requestNow } from '@/features/va/lanes';
import { carPhotos } from '@/server/car-photos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field jobs', path: '/staff/fleet', noindex: true, description: 'Field job scheduling and assignment.' });

// Fleet Operations (05-va.md section 3): every confirmed booking gets its handover and return jobs by itself, at the booking's
// times and place, given to the least busy field staff member who passed the academy and holds a shift that day (0880).
// The board is the one shared with the Admin's page (features/va/FieldJobs.tsx).
export default async function Fleet() {
  const { user, aal, read } = await vaPage('/staff/fleet', ['fleet']);
  const now = requestNow();
  const [b, cal] = await Promise.all([door<Board>(user.id, 'ops_read', 'field_board', {}, aal),
    read<{ vehicles: CalVehicle[] }>('calendar', { from: new Date(now - 86_400_000).toISOString(), to: new Date(now + 2 * 86_400_000).toISOString() }).then((c) => c.vehicles).catch(() => [] as CalVehicle[])]);
  const photos = await carPhotos([...b.unscheduled, ...b.jobs]);
  return <FieldJobsBoard b={b} cal={cal} now={now} photos={photos} base="/staff" />;
}
