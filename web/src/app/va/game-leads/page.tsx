import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { GameLeads, GameReportTiles, type GameLeadsData } from '@/features/games/GameLeads';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Game leads', path: '/va/game-leads', noindex: true, description: 'Discount game leads to call or email.' });

// My work > Game leads (migration 0069), customer service and Sales.
export default async function GameLeadsPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/va/game-leads', ['sales', 'cs']), searchParams]);
  const d = await read<GameLeadsData>('game_leads', { q: sp.q, status: sp.status, days: 30 });
  return (<><PageHead title="Game leads" kicker="My work" />
    <div className="stack"><GameLeads d={d} base="/va/game-leads" sp={sp} bookingBase="/va/bookings" /><GameReportTiles r={d.report} /></div></>);
}
