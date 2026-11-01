import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { liveMap } from '@/server/admin/live-map';
import { redirect } from 'next/navigation';
import { LiveMap } from '@/features/live-map/LiveMap';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Live map', path: '/admin/live-map', noindex: true, description: 'Leads, renters and visitors on a map of the Greater Toronto Area, for a TV or monitor.' });

// The Live map's TV mode (migration 0242): ?tv=1, full screen for a TV or monitor. Release 26: the map on a computer is
// the top of the Visitors page, so this address without ?tv=1 goes there. Drawn without phones and emails: the browser
// asks for them only when "Show contact" is on, so a TV left on never holds them.
export default async function LiveMapPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireAdmin('/admin/live-map'), searchParams]);
  if (sp.tv !== '1') redirect('/admin/visitors');
  const initial = await liveMap(user.id, false).catch(() => null);
  // the clock the page is drawn at: the browser starts from it, so its first render matches this one (no hydration error)
  const at = new Date().getTime();
  return <LiveMap initial={initial} tv at={at} />;
}
