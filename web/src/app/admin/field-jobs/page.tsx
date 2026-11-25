import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { FieldJobsBoard, type Board } from '@/features/va/FieldJobs';
import type { CalVehicle } from '@/features/va/carboard';
import { requestNow } from '@/features/va/lanes';
import { carPhotos } from '@/server/car-photos';
import { PrepPanel, WorkListsPanel, type PrepList, type WorkLists } from '@/features/field-portal/FleetPanels';
import { MissingHandovers } from '@/features/handover/MissingHandovers';
import { ShiftFeedCard } from '@/features/shift-feed/ShiftFeedCard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field jobs', path: '/admin/field-jobs', noindex: true, description: 'Field job scheduling, shifts and assignment.' });

// r35 (0880): an Admin opens the field jobs board directly, with every action Fleet has (the Admin is also assignable).
const ID = /^[0-9a-f-]{36}$/;
const one = (v: string | string[] | undefined) => (typeof v === 'string' && ID.test(v) ? v : null);
export default async function AdminFieldJobs({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ user, read }, sp] = await Promise.all([page('/admin/field-jobs'), searchParams]);
  const now = requestNow();
  const [b, cal] = await Promise.all([door<Board>(user.id, 'ops_read', 'field_board'),
    read<{ vehicles: CalVehicle[] }>('calendar', { from: new Date(now - 86_400_000).toISOString(), to: new Date(now + 2 * 86_400_000).toISOString() }).then((c) => c.vehicles).catch(() => [] as CalVehicle[])]);
  const photos = await carPhotos([...b.unscheduled, ...b.jobs]);
  // r35 part X (0930): each person's list of the day with its completion, and the onboarding prep
  const [wl, prep] = await Promise.all([door<WorkLists>(user.id, 'ops_read', 'field_work_lists', {}).catch(() => null), door<PrepList>(user.id, 'ops_read', 'field_prep', {}).catch(() => null)]);
  return <>{wl && <WorkListsPanel w={wl} />}<FieldJobsBoard b={b} cal={cal} now={now} photos={photos} base="/admin" focus={{ job: one(sp.job), slot: one(sp.slot) }} />{prep && <PrepPanel p={prep} />}<MissingHandovers userId={user.id} mode="admin" base="/admin" /><ShiftFeedCard userId={user.id} call="admin_read" /></>;
}
