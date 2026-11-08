import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { FieldJobsBoard, type Board } from '@/features/va/FieldJobs';
import type { CalVehicle } from '@/features/va/carboard';
import { requestNow } from '@/features/va/lanes';
import { carPhotos } from '@/server/car-photos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field jobs', path: '/admin/field-jobs', noindex: true, description: 'Field job scheduling, shifts and assignment.' });

// r35 (0880): an Admin opens the field jobs board directly, with every action Fleet has (the Admin is also assignable).
export default async function AdminFieldJobs() {
  const { user, read } = await page('/admin/field-jobs');
  const now = requestNow();
  const [b, cal] = await Promise.all([door<Board>(user.id, 'ops_read', 'field_board'),
    read<{ vehicles: CalVehicle[] }>('calendar', { from: new Date(now - 86_400_000).toISOString(), to: new Date(now + 2 * 86_400_000).toISOString() }).then((c) => c.vehicles).catch(() => [] as CalVehicle[])]);
  const photos = await carPhotos([...b.unscheduled, ...b.jobs]);
  return <FieldJobsBoard b={b} cal={cal} now={now} photos={photos} base="/admin" />;
}
