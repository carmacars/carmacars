import { money } from '@/lib/format';
import { basisLine, monthShort, pctOf, totals, type OwnerForecast } from './forecast';

// Release 48 O (3081): the Forecast section of the owner portal's home and of the Admin's view of an owner. The next 12
// months of each car: projected occupancy (the GTA season, blended with the car's own occupancy once it has 3 months) and
// projected owner revenue (before fees). One table a car, the first open; the cars together on top when there are several.
export function ForecastPanel({ f, admin = false, testId = 'owner-forecast' }: { f: OwnerForecast | null; admin?: boolean; testId?: string }) {
  const cars = (f?.cars ?? []).filter((c) => c?.months?.length);
  const all = f ? totals(f) : [];
  return (
    <section className="pu-panel ow-forecast" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <div className="pu-panel__head"><div><p className="pu-eyebrow">The next 12 months</p><h2 className="pu-title" id={`${testId}-h`}>Forecast</h2></div></div>
      {!cars.length ? <p className="small muted">The forecast starts once {admin ? 'a car of this owner' : 'your car'} is on the program.</p> : (
        <>
          <p className="small muted">An estimate, not a promise: projected occupancy and owner revenue before fees. Bookings hidden from {admin ? 'the owner' : 'you'} are not counted.</p>
          {cars.length > 1 && <p className="small" data-testid={`${testId}-total`}>All {cars.length} cars, the next 12 months: about <b>{money(all.reduce((s, m) => s + m.revenue_cents, 0))}</b> in owner revenue, {pctOf(Math.round(all.reduce((s, m) => s + m.occupancy_bps, 0) / all.length))} occupancy on average.</p>}
          {cars.map((c, i) => (
            <details key={c.vehicle_id} className="ow-forecast__car" open={i === 0} data-testid={`${testId}-car`}>
              <summary><b>{c.name}</b> <span className="small muted">about {money(c.months.reduce((s, m) => s + m.revenue_cents, 0))} over 12 months</span></summary>
              <p className="small muted">{basisLine(c)}</p>
              <table className="ow-forecast__table">
                <caption className="vh">{c.name}: the next 12 months</caption>
                <thead><tr><th scope="col">Month</th><th scope="col">Occupancy</th><th scope="col" className="num">Owner revenue</th></tr></thead>
                <tbody>{c.months.map((m) => (
                  <tr key={m.month}>
                    <th scope="row">{monthShort(m.month)}</th>
                    <td><span className="ow-forecast__bar" aria-hidden="true"><span style={{ width: `${Math.min(100, m.occupancy_bps / 100)}%` }} /></span> {pctOf(m.occupancy_bps)}</td>
                    <td className="num">{money(m.revenue_cents)}</td>
                  </tr>))}
                </tbody>
              </table>
            </details>
          ))}
        </>
      )}
    </section>
  );
}
