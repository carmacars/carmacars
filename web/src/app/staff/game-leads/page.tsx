import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { CapturedContacts, type CapturedData } from '@/features/capture/CapturedContacts';
import { GameLeads, GameReportTiles, type GameLeadsData } from '@/features/games/GameLeads';
import { NewRenterLeads } from '@/features/sales-leads/LeadList';
import type { LeadList } from '@/features/sales-leads/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Game leads', path: '/staff/game-leads', noindex: true, description: 'Discount game leads to call or email.' });

// Renters > Leads (migration 0069), customer service and Sales. r35 (0950): the new renter leads first, as cards with their
// actions; the contacts typed into forms and the discount game leads below, folded. r46: the game leads were the one read
// with no fallback, so a read that failed (the database busy) failed the whole page (React error 441 in client_errors):
// the page now renders the new leads and the contacts, and says the game leads did not load.
export default async function GameLeadsPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/staff/game-leads', ['sales', 'cs']), searchParams]);
  const [fresh, d, cap] = await Promise.all([read<LeadList>('sales_leads', { type: 'renter', status: 'open', sort: 'newest', limit: 60 }).catch(() => null), read<GameLeadsData>('game_leads', { q: sp.q, status: sp.status, days: 30 }).catch(() => null),
    read<CapturedData>('captured_contacts', { q: sp.q, days: 30 }).catch(() => ({ open: 0, rows: [] }))]);
  return (<><PageHead title="Renter leads" kicker="My work" />
    <div className="stack">{fresh && <NewRenterLeads d={fresh} base="/staff/sales-leads" listHref="/staff/sales-leads?type=renter" />}
      <details data-testid="older-leads-captured"><summary className="link">Contacts typed into forms ({cap.open})</summary><CapturedContacts d={cap} /></details>
      <details data-testid="older-leads-games" open={Boolean(sp.q || sp.status)}><summary className="link">Discount game leads</summary>{d ? <><GameLeads d={d} base="/staff/game-leads" sp={sp} bookingBase="/staff/bookings" />{d.report ? <GameReportTiles r={d.report} /> : null}</>
        : <p className="alert alert--warn" role="status" data-testid="game-leads-unavailable"><span>The discount game leads did not load just now. Reload the page in a minute.</span></p>}</details></div></>);
}
