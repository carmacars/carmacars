import Link from 'next/link';
import { $, Card, Table, label } from '@/features/admin/ui';
import { conversion, type SalesFigures } from './SalesBoard';

// The team's sales for one month (migration 0057), on Admin > Today > Overview: each person in Sales, and anyone else
// with a quote, an offer, a rental added or a booking credited that month. Tracking only, no commission.
export interface TeamRow extends SalesFigures { staff_id: string; name: string; function: string | null; in_sales: boolean; follow_ups: number }
export interface Team { month: string; label: string; months: string[]; rows: TeamRow[]; totals: { quotes: number; rentals_added: number; offers_sent: number; confirmed: number; revenue_cents: number; follow_ups: number } }

const monthName = (ym: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${ym}-15T12:00:00Z`));

export function TeamSales({ team }: { team: Team }) {
  return (
    <Card title={`Sales in ${team.label}`} testId="team-sales" aside={
      <form className="row" action="/admin/overview" method="get" aria-label="Choose the month">
        <label className="vh" htmlFor="team-sales-month">Month</label>
        <select className="select" id="team-sales-month" name="sales_month" defaultValue={team.month} data-testid="team-sales-month">
          {team.months.map((m) => <option key={m} value={m}>{monthName(m)}</option>)}
        </select>
        <button className="btn btn--ghost btn--sm" type="submit">Show</button>
      </form>}>
      <Table<TeamRow & Record<string, unknown>> caption={`Sales in ${team.label}`} rows={team.rows as Array<TeamRow & Record<string, unknown>>} rowKey={(r) => r.staff_id}
        empty="No one in Sales yet, and no quotes, offers or rentals this month." cols={[
          { key: 'name', label: 'Staff member', render: (r) => <><Link prefetch={false} className="link" href={`/admin/staff/${r.staff_id}/sales`}>{r.name}</Link> <span className="muted small">{label(r.function)}</span></> },
          { key: 'quotes', label: 'Quotes', num: true }, { key: 'offers_sent', label: 'Offers sent', num: true }, { key: 'rentals_added', label: 'Rentals added', num: true },
          { key: 'confirmed', label: 'Confirmed', num: true }, { key: 'conversion_bps', label: 'Conversion', num: true, render: (r) => conversion(r.conversion_bps) },
          { key: 'revenue_cents', label: 'Booked revenue', num: true, render: (r) => $(r.revenue_cents) }, { key: 'follow_ups', label: 'Follow-ups due', num: true }]} />
      {team.rows.length > 1 && <p className="small" data-testid="team-sales-totals">Team: {team.totals.quotes} quotes, {team.totals.offers_sent} offers sent, {team.totals.rentals_added} rentals added, {team.totals.confirmed} bookings confirmed, {$(team.totals.revenue_cents)} booked revenue.</p>}
      <p className="small muted">Booked revenue is the rental charge before tax, after discounts, refunds and cancellations, for bookings confirmed in the month. Tracking only: no commission is paid.</p>
    </Card>
  );
}
