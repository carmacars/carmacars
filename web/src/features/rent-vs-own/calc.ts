// Renting vs owning (release 36, part 11; migrations 2003, 2004): the monthly cost of owning a model year, line by line,
// each from a source or a Program setting (shown as a CarmaCars assumption), against the CarmaCars monthly rental.
// A line whose input is missing is left out, never guessed. Pure, relative imports only.

export interface OwnCost { component: 'insurance' | 'parking' | 'registration'; scope: string; monthly_cents: number; note: string | null; source: string; source_url: string }
export interface OwnInputs {
  apr_bps: number; term_months: number; km_per_month: number; depreciation_bps: number; cleaning_monthly_cents: number | null;
  gas_cents: number; premium_extra_cents: number; kwh_cents: number;
  costs: OwnCost[]; specs: Array<{ field: string; value: string; source: string; source_url: string }>;
  catalog: { vclass: string | null; l100_min: number | null; kwh100_min: number | null } | null;
  rental: { monthly_cents: number; class: string } | null; rental_any: number | null;
  maintenance?: { per_year_cents: number; per_10k_km_cents: number; assumptions: string; source: string; source_url: string } | null;
}
export interface OwnLine { key: string; label: string; monthly_cents: number; basis: string; source: string; source_url?: string }

/** The monthly payment of a loan: principal, yearly rate in basis points, months. */
export function loanPayment(principalCents: number, aprBps: number, months: number): number {
  const r = aprBps / 10000 / 12;
  if (r === 0) return Math.round(principalCents / months);
  return Math.round((principalCents * r) / (1 - Math.pow(1 + r, -months)));
}
const pct = (bps: number) => `${+(bps / 100).toFixed(2)}%`;
const $ = (c: number) => `$${(c / 100).toLocaleString('en-CA', { maximumFractionDigits: 0 })}`;

export function ownLines(x: OwnInputs, year: number, now = new Date().getUTCFullYear()): { lines: OwnLine[]; insurance: OwnCost[]; msrp: number | null } {
  const lines: OwnLine[] = [];
  const spec = (f: string) => x.specs.find((s) => s.field === f);
  const m = spec('msrp_cad');
  const msrp = m && Number(m.value) > 0 ? Math.round(Number(m.value) * 100) : null;
  const age = Math.max(0, now - year);
  if (msrp) {
    const value = Math.round(msrp * Math.pow(1 - x.depreciation_bps / 10000, age));
    lines.push({ key: 'financing', label: 'Financing', monthly_cents: loanPayment(value, x.apr_bps, x.term_months),
      basis: `${$(value)} financed over ${x.term_months} months at ${pct(x.apr_bps)} (${age ? `the MSRP of ${$(msrp)} less ${pct(x.depreciation_bps)} a year for ${age} ${age === 1 ? 'year' : 'years'}` : `the MSRP of ${$(msrp)}`}; rate and term are CarmaCars assumptions)`,
      source: `MSRP: ${m!.source}`, source_url: m!.source_url });
    lines.push({ key: 'depreciation', label: 'Depreciation', monthly_cents: Math.round((value * x.depreciation_bps) / 10000 / 12),
      basis: `${pct(x.depreciation_bps)} a year of ${$(value)} (a CarmaCars assumption)`, source: 'Program settings' });
  }
  const l100 = Number(spec('fuel_combined_l100')?.value) || x.catalog?.l100_min || null;
  const kwh = Number(spec('kwh100_combined')?.value) || x.catalog?.kwh100_min || null;
  if (kwh) lines.push({ key: 'fuel', label: 'Electricity', monthly_cents: Math.round((kwh * x.km_per_month * x.kwh_cents) / 100), basis: `${kwh} kWh/100 km for ${x.km_per_month.toLocaleString('en-CA')} km a month at ${x.kwh_cents} cents a kWh`, source: 'US EPA, Program settings' });
  else if (l100) lines.push({ key: 'fuel', label: 'Fuel', monthly_cents: Math.round((Number(l100) * x.km_per_month * x.gas_cents) / 100), basis: `${l100} L/100 km for ${x.km_per_month.toLocaleString('en-CA')} km a month at ${x.gas_cents} cents a litre`, source: 'US EPA, Program settings' });
  if (x.maintenance) lines.push({ key: 'maintenance', label: 'Maintenance', monthly_cents: Math.round(Math.max(x.maintenance.per_year_cents / 12, (x.maintenance.per_10k_km_cents * x.km_per_month) / 10000)),
    basis: x.maintenance.assumptions, source: x.maintenance.source, source_url: x.maintenance.source_url });
  for (const c of x.costs.filter((c) => c.component !== 'insurance')) lines.push({ key: c.component, label: c.component === 'parking' ? 'Parking' : 'Registration', monthly_cents: c.monthly_cents, basis: c.note ?? '', source: c.source, source_url: c.source_url });
  if (x.cleaning_monthly_cents) lines.push({ key: 'cleaning', label: 'Cleaning and detailing', monthly_cents: x.cleaning_monthly_cents, basis: 'A CarmaCars assumption', source: 'Program settings' });
  return { lines, insurance: x.costs.filter((c) => c.component === 'insurance'), msrp };
}
