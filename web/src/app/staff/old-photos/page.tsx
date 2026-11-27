import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { OldPhotos } from '@/features/old-photos/OldPhotos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add old photos', path: '/staff/old-photos', noindex: true, description: 'Add check-in and check-out photos taken earlier to past bookings.' });

// R50 hotfix 2 (5185): Fleet and customer service add photos of earlier check-ins and check-outs, as field staff do.
export default async function StaffOldPhotos({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/staff/old-photos', ['fleet', 'cs']), searchParams]);
  return (<><PageHead title="Add old photos" purpose="Check-in and check-out photos taken earlier, onto the past booking. They show on its photo report as added later." /><OldPhotos userId={user.id} aal={aal} base="/staff/old-photos" sp={sp} /></>);
}
