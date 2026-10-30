import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { CapturedContacts, type CapturedData } from '@/features/capture/CapturedContacts';
import { GameLeads, GameReportTiles, type GameLeadsData } from '@/features/games/GameLeads';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Game leads', path: '/staff/game-leads', noindex: true, description: 'Discount game leads to call or email.' });

// My work > Game leads (migration 0069), customer service and Sales.
export default async function GameLeadsPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/staff/game-leads', ['sales', 'cs']), searchParams]);
  const [d, cap] = await Promise.all([read<GameLeadsData>('game_leads', { q: sp.q, status: sp.status, days: 30 }),
    read<CapturedData>('captured_contacts', { q: sp.q, days: 30 }).catch(() => ({ open: 0, rows: [] }))]);
  return (<><PageHead title="Game leads" kicker="My work" />
    <div className="stack"><CapturedContacts d={cap} /><GameLeads d={d} base="/staff/game-leads" sp={sp} bookingBase="/staff/bookings" /><GameReportTiles r={d.report} /></div></>);
}
