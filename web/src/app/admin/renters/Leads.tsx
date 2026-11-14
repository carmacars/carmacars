import type { AdminPage } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { CapturedContacts, type CapturedData } from '@/features/capture/CapturedContacts';
import { ExpiredOfferLeads, type ExpiredLead, type LeadPhoneState } from './ExpiredOfferLeads';
import { GameLeads, GameReportTiles, type GameLeadsData } from '@/features/games/GameLeads';
import { NewRenterLeads } from '@/features/sales-leads/LeadList';
import type { LeadList } from '@/features/sales-leads/model';


// People > Renters > Leads (migration 0069; r27: a tab of Renters, /admin/leads redirects). r35 (0950): the new leads first
// (live chat, contact form, phone box, requests not sent, missed calls, Live visitors), as cards with their actions; the
// expired offers, the contacts typed into forms and the discount game leads below, folded.
export async function Leads({ ctx: { read, list }, sp }: { ctx: Pick<AdminPage, 'read' | 'list'>; sp: Record<string, string | undefined> }) {
  const [fresh, d, cap, exp] = await Promise.all([read<LeadList>('sales_leads', { type: 'renter', status: 'open', sort: 'newest', limit: 60 }).catch(() => null),
    read<GameLeadsData>('game_leads', { q: sp.q, status: sp.status, days: 30 }),
    read<CapturedData>('captured_contacts', { q: sp.q, days: 30 }).catch(() => ({ open: 0, rows: [] })),
    list<ExpiredLead>('leads', { eq: { source: ['expired_offer'] }, order: 'created_at', limit: 50 }).catch(() => ({ rows: [] as ExpiredLead[], count: 0 }))]);
  // 2870: Show the phone to the lead's salesperson, as on the lead cards
  const ids = exp.rows.filter((r) => r.phone).map((r) => r.id);
  const phones = ids.length ? await read<LeadPhoneState>('lead_phone_state', { leads: ids }).catch(() => ({} as LeadPhoneState)) : ({} as LeadPhoneState);
  return (<><PageHead title="Renter leads" purpose="People who are not renters yet: contact details typed into the site's forms, discount game leads, and offers that expired a week ago or more." />
    <div className="stack">{fresh && <NewRenterLeads d={fresh} base="/admin/sales-leads" listHref="/admin/sales-leads?type=renter" />}
      <details data-testid="older-leads-expired"><summary className="link">Expired offers ({exp.count})</summary><ExpiredOfferLeads rows={exp.rows} count={exp.count} phones={phones} /></details>
      <details data-testid="older-leads-captured"><summary className="link">Contacts typed into forms ({cap.open})</summary><CapturedContacts d={cap} renterBase="/admin/renters" /></details>
      <details data-testid="older-leads-games" open={Boolean(sp.q || sp.status)}><summary className="link">Discount game leads</summary><GameReportTiles r={d.report} settingsHref="/admin/settings/discount-games" /><GameLeads d={d} base="/admin/renters?tab=leads" sp={sp} bookingBase="/admin/bookings" /></details></div></>);
}
