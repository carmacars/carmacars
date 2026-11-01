import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { liveMap } from '@/server/admin/live-map';
import { PageHead } from '@/features/admin/ui';
import { LiveMap } from '@/features/live-map/LiveMap';
import { LiveVisitors } from '@/features/live/LiveVisitors';
import type { LiveData } from '@/features/live/staff';
import { liveWithoutContact } from '@/features/live/contact';
import { HistoryList } from '@/features/visitors/HistoryList';
import { historyParams, type HistoryData } from '@/features/visitors/history';
import '@/features/visitors/visitors.css';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Visitors', path: '/admin/visitors', noindex: true, description: 'Who is on the site now and who came before, on the map and in one list.' });

// Today > Visitors (Release 26): Live visitors, Visitor history and the Live map in one page (the owner: "why is there
// live visitors, visitor history and live map all as separate tabs"). The map on top with its cards; under it one list
// with a switch: Live now (who is on the site, with naming, chat and the one-click actions) or History (past visits),
// each with its filters; a row finds its lead on the map. TV mode stays its own full screen (/admin/live-map?tv=1).
// The old addresses send here. Admins only, as the three were. Drawn without any phone or email: the browser asks for
// them only when "Show contact" is on.
export default async function Visitors({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ user, read }, sp] = await Promise.all([page('/admin/visitors'), searchParams]);
  const view = sp.view === 'history' ? 'history' : 'live';
  const [map, live, hist] = await Promise.all([
    liveMap(user.id, false).catch(() => null),
    view === 'live' ? read<LiveData>('live_visitors').then(liveWithoutContact) : Promise.resolve(null),
    view === 'history' ? read<HistoryData>('visitor_history', historyParams(sp)) : Promise.resolve(null)
  ]);
  const at = new Date().getTime();
  const tab = (v: 'live' | 'history', label: string) => (
    <Link prefetch={false} href={v === 'live' ? '/admin/visitors' : '/admin/visitors?view=history'} className={`vs-tab${view === v ? ' is-on' : ''}`}
      aria-current={view === v ? 'page' : undefined} data-testid={`vs-tab-${v}`}>{label}</Link>
  );
  return (
    <>
      <PageHead title="Visitors" kicker="Today" purpose="Who is on the site now and who came before: on the map with their cards, and in one list below. Press a lead for its card." />
      <div className="vs" data-testid="visitors">
        <LiveMap initial={map} tv={false} at={at} embedded />
        <section className="vs-panel" aria-label={view === 'live' ? 'Live now' : 'History'}>
          <div className="vs-panel__head">
            <nav className="vs-tabs" aria-label="Visitors list">{tab('live', 'Live now')}{tab('history', 'History')}</nav>
            <div className="vs-panel__links small">
              <Link prefetch={false} className="link" href="/admin/chat">Live chat</Link>
              {view === 'history' && <Link prefetch={false} className="link" href="/admin/live/signals">Signal settings</Link>}
            </div>
          </div>
          {view === 'live' && live ? <LiveVisitors initial={live} portal="admin" inVisitors /> : hist ? <HistoryList d={hist} sp={sp} /> : null}
        </section>
      </div>
    </>
  );
}
