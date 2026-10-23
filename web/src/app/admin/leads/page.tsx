import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { CapturedContacts, type CapturedData } from '@/features/capture/CapturedContacts';
import { GameLeads, GameReportTiles, type GameLeadsData } from '@/features/games/GameLeads';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renter leads', path: '/admin/leads', noindex: true, description: 'Contact details typed into forms, and discount game leads: prizes claimed, codes used, consent and visits.' });

// Bookings > Renter leads (migration 0069): the discount game leads and the game's report.
export default async function Leads({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/leads'), searchParams]);
  const [d, cap] = await Promise.all([read<GameLeadsData>('game_leads', { q: sp.q, status: sp.status, days: 30 }),
    read<CapturedData>('captured_contacts', { q: sp.q, days: 30 }).catch(() => ({ open: 0, rows: [] }))]);
  return (<><PageHead title="Renter leads" kicker="Bookings" purpose="Contact details typed into the site's forms, and discount game leads." />
    <div className="stack"><CapturedContacts d={cap} renterBase="/admin/renters" /><GameReportTiles r={d.report} settingsHref="/admin/settings/discount-games" /><GameLeads d={d} base="/admin/leads" sp={sp} bookingBase="/admin/bookings" /></div></>);
}
