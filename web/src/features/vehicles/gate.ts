// The vehicle pages' indexing gate (migration 0092, app.vpage_gate in SQL: the same rules, kept in step by
// gate.test.ts and supabase/tests/55_vehicle_pages.sql). "all" (the owner's default, October 21, 2026) indexes every
// page; "rules" indexes makes, models with enough years of data or one of our real cars, years with enough of our real
// cars or of a popular model from the set year, and trims with enough of our real cars.
export type GateSettings = { index_mode: 'all' | 'rules'; model_min_years: number; popular_from_year: number; year_min_cars: number; trim_min_cars: number };
export type Level = 'make' | 'model' | 'year' | 'trim';

export function vpageGate(level: Level, o: { years?: number; realCars?: number; popular?: boolean; year?: number }, s: GateSettings): boolean {
  if (s.index_mode === 'all') return true;
  const cars = o.realCars ?? 0;
  switch (level) {
    case 'make': return true;
    case 'model': return (o.years ?? 0) >= s.model_min_years || cars >= 1;
    case 'year': return cars >= s.year_min_cars || (!!o.popular && (o.year ?? 0) >= s.popular_from_year);
    case 'trim': return cars >= s.trim_min_cars;
  }
}

/** The page a noindexed page names as its canonical: its parent. */
export function parentPath(path: string): string {
  const parts = path.split('/').filter(Boolean);
  return parts.length <= 2 ? `/${parts.join('/')}` : `/${parts.slice(0, -1).join('/')}`;
}

/** The rules in words, for Admin > Settings > Vehicle pages. */
export function gateRules(s: GateSettings): Array<[Level, string]> {
  if (s.index_mode === 'all') return [['make', 'Every page is indexed and in the sitemaps, with its own canonical (the default).']];
  return [
    ['make', 'Every make page.'],
    ['model', `Models with ${s.model_min_years} or more years of data, or one of our real cars.`],
    ['year', `Years with ${s.year_min_cars} or more of our real cars of that year, or of a popular model from ${s.popular_from_year} on.`],
    ['trim', `Trims with ${s.trim_min_cars} or more of our real cars of that exact trim.`]
  ];
}
