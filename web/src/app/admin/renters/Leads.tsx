import type { AdminPage } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { CapturedContacts, type CapturedData } from '@/features/capture/CapturedContacts';
import { GameLeads, GameReportTiles, type GameLeadsData } from '@/features/games/GameLeads';


// People > Renters > Leads (migration 0069; r27: a tab of Renters, /admin/leads redirects): contacts typed into the site's
// forms, the discount game leads and the game's report.
export async function Leads({ ctx: { read }, sp }: { ctx: Pick<AdminPage, 'read'>; sp: Record<string, string | undefined> }) {
  const [d, cap] = await Promise.all([read<GameLeadsData>('game_leads', { q: sp.q, status: sp.status, days: 30 }),
    read<CapturedData>('captured_contacts', { q: sp.q, days: 30 }).catch(() => ({ open: 0, rows: [] }))]);
  return (<><PageHead title="Renter leads" purpose="People who are not renters yet: contact details typed into the site's forms, and discount game leads." />
    <div className="stack"><CapturedContacts d={cap} renterBase="/admin/renters" /><GameReportTiles r={d.report} settingsHref="/admin/settings/discount-games" /><GameLeads d={d} base="/admin/renters?tab=leads" sp={sp} bookingBase="/admin/bookings" /></div></>);
}
