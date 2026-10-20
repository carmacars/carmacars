import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, Filters, Search, Table, Tiles, t } from '@/features/admin/ui';

// Discount games (migration 0069), staff side: who claimed a prize, whether the code was used, their consent and what
// they looked at, with call, email and "contacted" one tap away; and the report (plays, claims, codes used, bookings
// and revenue). Admin > Bookings > Leads and the assistants' Game leads (customer service and Sales).
type R = Record<string, unknown>;
export interface GameReport { days: number; plays: number; revealed: number; claims: number; claim_rate_bps: number; with_consent: number; on_requests: number; bookings: number;
  redemption_rate_bps: number; revenue_cents: number; discount_cents: number; by_game: Array<{ game: string; plays: number; claims: number; bookings: number }>;
  by_prize: Array<{ prize: string; claims: number; bookings: number }> }
export interface GameLeadsData { rows: R[]; report: GameReport }
const GAME: Record<string, string> = { wheel: 'Spin the wheel', scratch: 'Scratch to reveal', blackjack: 'Quick blackjack', cups: 'Cup shuffle', plinko: 'Plinko' };
const STATUS: Record<string, string> = { unused: 'Not used yet', on_request: 'On a request', used: 'Used (booked)', expired: 'Expired' };
const pct = (bps: number) => `${(bps / 100).toFixed(bps % 100 ? 1 : 0)}%`;

export function GameReportTiles({ r, settingsHref }: { r: GameReport; settingsHref?: string }) {
  return (<>
    <Tiles items={[
      { k: `Plays, ${r.days} days`, v: r.plays, sub: `${r.revealed} played to the prize` },
      { k: 'Claims', v: r.claims, sub: `${pct(r.claim_rate_bps)} of plays, ${r.with_consent} with marketing consent` },
      { k: 'Codes on requests', v: r.on_requests },
      { k: 'Bookings', v: r.bookings, sub: `${pct(r.redemption_rate_bps)} of claims` },
      { k: 'Revenue from game codes', v: $(r.revenue_cents), sub: 'rental charge after discounts, confirmed bookings' },
      { k: 'Discounts given', v: $(r.discount_cents), sub: 'shared with the owner like every promo code' }]} />
    <div className="ad-cols ad-cols--2">
      <Card title="By game"><Table rows={r.by_game as unknown as R[]} rowKey={(x) => String(x.game)} cols={[{ key: 'game', label: 'Game', render: (x) => GAME[String(x.game)] ?? String(x.game) },
        { key: 'plays', label: 'Plays', num: true }, { key: 'claims', label: 'Claims', num: true }, { key: 'bookings', label: 'Bookings', num: true }]} /></Card>
      <Card title="By prize" aside={settingsHref ? <Link prefetch={false} className="link small" href={settingsHref}>Settings</Link> : undefined}>
        <Table rows={r.by_prize as unknown as R[]} rowKey={(x) => String(x.prize)} cols={[{ key: 'prize', label: 'Prize' }, { key: 'claims', label: 'Claims', num: true }, { key: 'bookings', label: 'Bookings', num: true }]} /></Card>
    </div>
  </>);
}

export function GameLeads({ d, base, sp, bookingBase }: { d: GameLeadsData; base: string; sp: Record<string, string | undefined>; bookingBase: string }) {
  const refresh = [base];
  return (<>
    <Card title={`Discount game leads (${d.rows.length})`} testId="game-leads">
      <div className="ad-actions">
        <Search action={base} value={sp.q} placeholder="Search name, email, phone or code" />
        <Filters base={base} name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['unused', 'Not used yet'], ['on_request', 'On a request'], ['used', 'Booked'], ['expired', 'Expired']]} />
      </div>
      <Table rows={d.rows} rowKey={(r) => String(r.claim_id)} empty="No claims yet. The game shows to visitors who browse a few cars." cols={[
        { key: 'created_at', label: 'Claimed', render: (r) => t(r.created_at) },
        { key: 'first_name', label: 'Name', render: (r) => <>{String(r.first_name)}{r.on_site_now ? <> <Badge s="live">on the site now</Badge></> : null}</> },
        { key: 'contact', label: 'Contact', className: 'wrap', render: (r) => <>
          <a className="link" href={`mailto:${String(r.email)}`}>{String(r.email)}</a>
          {r.phone ? <><br /><a className="link" href={`tel:${String(r.phone)}`}>{String(r.phone)}</a></> : null}</> },
        { key: 'prize_label', label: 'Prize', render: (r) => <>{String(r.prize_label)}<br /><span className="small muted">{GAME[String(r.game)] ?? String(r.game)}</span></> },
        { key: 'code', label: 'Code', render: (r) => <code>{String(r.code)}</code> },
        { key: 'status', label: 'Used', render: (r) => <>{STATUS[String(r.status)] ?? String(r.status)}{r.booking_number ? <><br /><Link prefetch={false} className="link small" href={`${bookingBase}/${encodeURIComponent(String(r.booking_number))}`}>{String(r.booking_number)}</Link></> : null}</> },
        { key: 'marketing_consent', label: 'Marketing', render: (r) => (r.marketing_consent ? 'Yes' : 'No') },
        { key: 'visit', label: 'Visit', className: 'wrap', render: (r) => `${Number(r.cars_viewed)} cars, ${Number(r.pages_viewed)} pages, ${Math.round(Number(r.seconds_on_site) / 60)} min${Number(r.visits) > 1 ? `, ${Number(r.visits)} visits` : ''}${r.city ? `, ${String(r.city)}` : ''}${r.device ? `, ${String(r.device)}` : ''}` },
        { key: 'lead_status', label: 'Follow-up', render: (r) => <>{String(r.lead_status ?? 'new')}{r.assigned_name ? <><br /><span className="small muted">{String(r.assigned_name)}</span></> : null}</> },
        { key: 'act', label: '', render: (r) => <span className="ad-actions">
          {r.phone ? <a className="btn btn--ghost btn--sm" href={`tel:${String(r.phone)}`}>Call</a> : null}
          <a className="btn btn--ghost btn--sm" href={`mailto:${String(r.email)}?subject=${encodeURIComponent('Your CarmaCars code ' + String(r.code))}`}>Email</a>
          {r.lead_id && r.lead_status === 'new' ? <Act ops action="game_lead_update" payload={{ id: r.lead_id, status: 'contacted', take: true }} label="Contacted" refresh={refresh} testId={`game-contacted-${String(r.code)}`} /> : null}
          {r.lead_id && r.lead_status !== 'closed' && r.lead_status !== 'converted' ? <Act ops action="game_lead_update" payload={{ id: r.lead_id }} label="Close" refresh={refresh}
            fields={[{ name: 'status', label: 'Status', type: 'select', required: true, value: 'closed', options: [['closed', 'Closed'], ['qualified', 'Qualified'], ['spam', 'Spam']] }, { name: 'closed_reason', label: 'Reason', type: 'text' }]} /> : null}
        </span> }]} />
      <p className="small muted">The code email went to every address above (transactional). Offers go only to people with marketing consent. A visitor who viewed several cars also gets a Sales task.</p>
    </Card>
  </>);
}
