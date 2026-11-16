// Release 48 O (3081): the owner's monthly occupancy forecast (app.owner_occupancy_forecast, ops_read owner_forecast).
// Each car: the next 12 months, its projected occupancy (the GTA seasonal curve blended with the car's own occupancy once
// it has 3 months of history) and projected owner revenue (before fees). Pure, for the unit test.
export interface ForecastMonth { month: string; curve_bps: number; own_bps: number | null; occupancy_bps: number; days: number; revenue_cents: number }
export interface CarForecast { vehicle_id: string; name: string; from: string; history_months: number; own_weight: number; own_level_bps: number | null;
  day_cents: number; day_from: 'statements' | 'rate'; months: ForecastMonth[] }
export interface OwnerForecast { owner_id: string; base_pct: number; season: Record<string, number>; cars: CarForecast[] }
export interface StatementForecast { this_month: string; next_month: string; this_bps: number; next_bps: number; diff_points: number; this_cents: number;
  next_cents: number; diff_cents: number; direction: 'higher' | 'lower' | 'same'; reason: string; text: string }

export const pctOf = (bps: number) => `${Math.round(bps / 100)}%`;
export const monthShort = (iso: string) => new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { month: 'short', year: 'numeric', timeZone: 'UTC' });

/** How the car's forecast is made, in one line. */
export function basisLine(c: Pick<CarForecast, 'history_months' | 'own_weight' | 'day_from'>): string {
  const season = c.history_months >= 3
    ? `The GTA season blended with this car's own ${c.history_months} months (its own occupancy counts for ${Math.round(c.own_weight * 100)}%).`
    : `The GTA season only: the car's own occupancy counts once it has 3 full months (${c.history_months} so far).`;
  const rev = c.day_from === 'statements' ? 'Revenue from its own statements of the last 12 months, per booked day.' : 'Revenue from its daily rate, less the Revenue Share.';
  return `${season} ${rev}`;
}

/** The owner's cars together, month by month (the occupancy averaged, the revenue added up). */
export function totals(f: Pick<OwnerForecast, 'cars'>): Array<{ month: string; occupancy_bps: number; revenue_cents: number }> {
  const cars = f.cars.filter((c) => c?.months?.length);
  if (!cars.length) return [];
  return cars[0]!.months.map((m, i) => {
    const row = cars.map((c) => c.months[i]).filter((x): x is ForecastMonth => !!x);
    return { month: m.month, occupancy_bps: Math.round(row.reduce((s, x) => s + x.occupancy_bps, 0) / row.length), revenue_cents: row.reduce((s, x) => s + x.revenue_cents, 0) };
  });
}
