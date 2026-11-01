import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { liveMap } from '@/server/admin/live-map';
import { PageHead } from '@/features/admin/ui';
import { LiveMap } from '@/features/live-map/LiveMap';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Live map', path: '/admin/live-map', noindex: true, description: 'Leads, renters and visitors on a map of the Greater Toronto Area, for a TV or monitor.' });

// Today > Live map (migration 0242). ?tv=1: full screen for a TV or monitor, personal details masked.
export default async function LiveMapPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireAdmin('/admin/live-map'), searchParams]);
  const tv = sp.tv === '1';
  const initial = await liveMap(user.id, false).catch(() => null);
  // the clock the page is drawn at: the browser starts from it, so its first render matches this one (no hydration error)
  const at = new Date().getTime();
  if (tv) return <LiveMap initial={initial} tv at={at} />;
  return (<><PageHead title="Live map" kicker="Today" purpose="Leads, bookings, renters and visitors on the map, with their score and the car they looked at last. Open TV mode for a monitor in the office." />
    <LiveMap initial={initial} tv={false} at={at} /></>);
}
