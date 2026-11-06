import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';

// The cars of the owners you referred (migration 0543), read only: what each earns and how much it is used, the trips
// coming up, and the referral share already paid to you. Never the other owner's name or details.
export interface ReferredCar {
  vehicle_id: string; name: string | null; fleet_number: string | null; status: string; share_bps: number;
  days_booked_30: number; bookings_month: number; revenue_month_cents: number; revenue_3m_cents: number; share_paid_cents: number;
  upcoming: Array<{ pickup_at: string; return_at: string; status: string }>;
}

export function ReferredCars({ cars }: { cars: ReferredCar[] }) {
  return (
    <ul className="ow-cars" data-testid="referred-cars">
      {cars.map((c) => (
        <li key={c.vehicle_id} className="pt-card stack" data-testid="referred-car">
          <div className="pt-card__head"><h2 className="d4">{c.name ?? 'Car'}{c.fleet_number ? ` · ${c.fleet_number}` : ''}</h2><span className="small muted">Your share: {(c.share_bps / 100).toFixed(c.share_bps % 100 ? 2 : 0)} points of its revenue</span></div>
          <dl className="pt-dl pt-dl--money">
            <div><dt>Used in the last 30 days</dt><dd>{Math.round((Number(c.days_booked_30) / 30) * 100)}% ({Number(c.days_booked_30).toFixed(1)} days)</dd></div>
            <div><dt>Bookings this month</dt><dd>{c.bookings_month}</dd></div>
            <div><dt>Revenue this month</dt><dd>{money(c.revenue_month_cents, { cents: true })}</dd></div>
            <div><dt>Revenue, last 3 months</dt><dd>{money(c.revenue_3m_cents, { cents: true })}</dd></div>
            <div><dt>Referral share paid to you</dt><dd>{money(c.share_paid_cents, { cents: true })}</dd></div>
          </dl>
          {c.upcoming.length > 0 && <div><p className="small"><b>Booked</b></p><ul className="small">{c.upcoming.slice(0, 6).map((u) => <li key={u.pickup_at}>{when(u.pickup_at)} to {when(u.return_at)}</li>)}</ul></div>}
        </li>
      ))}
    </ul>
  );
}
