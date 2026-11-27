import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { OldPhotos } from '@/features/old-photos/OldPhotos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add old photos', path: '/admin/old-photos', noindex: true, description: 'Add check-in and check-out photos taken earlier to past bookings.' });

// R50 hotfix 2 (5185): the same screen as field staff's, for an Admin.
export default async function AdminOldPhotos({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/old-photos'), searchParams]);
  return (<><PageHead title="Add old photos" kicker="Cars" purpose="Check-in and check-out photos taken earlier, onto the past booking. They show on its photo report as added later." /><OldPhotos userId={user.id} base="/admin/old-photos" sp={sp} /></>);
}
