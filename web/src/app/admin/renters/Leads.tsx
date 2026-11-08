import type { AdminPage } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { CapturedContacts, type CapturedData } from '@/features/capture/CapturedContacts';
import { ExpiredOfferLeads, type ExpiredLead } from './ExpiredOfferLeads';
import { GameLeads, GameReportTiles, type GameLeadsData } from '@/features/games/GameLeads';


// People > Renters > Leads (migration 0069; r27: a tab of Renters, /admin/leads redirects): contacts typed into the site's
// forms, the discount game leads and the game's report.
export async function Leads({ ctx: { read, list }, sp }: { ctx: Pick<AdminPage, 'read' | 'list'>; sp: Record<string, string | undefined> }) {
  const [d, cap, exp] = await Promise.all([read<GameLeadsData>('game_leads', { q: sp.q, status: sp.status, days: 30 }),
    read<CapturedData>('captured_contacts', { q: sp.q, days: 30 }).catch(() => ({ open: 0, rows: [] })),
    list<ExpiredLead>('leads', { eq: { source: ['expired_offer'] }, order: 'created_at', limit: 50 }).catch(() => ({ rows: [] as ExpiredLead[], count: 0 }))]);
  return (<><PageHead title="Renter leads" purpose="People who are not renters yet: contact details typed into the site's forms, discount game leads, and offers that expired a week ago or more." />
    <div className="stack"><ExpiredOfferLeads rows={exp.rows} count={exp.count} /><CapturedContacts d={cap} renterBase="/admin/renters" /><GameReportTiles r={d.report} settingsHref="/admin/settings/discount-games" /><GameLeads d={d} base="/admin/renters?tab=leads" sp={sp} bookingBase="/admin/bookings" /></div></>);
}
