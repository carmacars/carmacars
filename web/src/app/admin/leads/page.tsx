import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { GameLeads, GameReportTiles, type GameLeadsData } from '@/features/games/GameLeads';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Leads', path: '/admin/leads', noindex: true, description: 'Discount game leads: prizes claimed, codes used, consent and visits.' });

// Bookings > Leads (migration 0069): the discount game leads and the game's report.
export default async function Leads({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/leads'), searchParams]);
  const d = await read<GameLeadsData>('game_leads', { q: sp.q, status: sp.status, days: 30 });
  return (<><PageHead title="Leads" kicker="Bookings" />
    <div className="stack"><GameReportTiles r={d.report} settingsHref="/admin/settings/discount-games" /><GameLeads d={d} base="/admin/leads" sp={sp} bookingBase="/admin/bookings" /></div></>);
}
