// The internal company model (Admin only): Actuals, the Forecast and the Pro forma of the CarmaCars model workbook,
// run from the database. Actual months come from the summary table the hourly job fills (finance_model_actuals,
// migration 0420); the forecast runs from the latest complete actual month plus the assumptions an Admin saves
// (finance_model_settings.inputs). The downloaded workbook (./workbook.ts) writes these same steps as live formulas.
//
// One forecast month k (1, 2, ... after the base month B):
//   cars        = cars(B) + cars added a month x min(k, months of adding)
//   utilization = util(B) + (target - util(B)) x min(1, k / ramp months)
//   rate/day    = rate(B) x (1 + rate growth) ^ floor((k - 1) / 12)
//   rented days = cars x utilization x 30.4
//   rental      = rented days x rate/day; fees = rental x fee %; paid out = rental x (1 - company keep %)
//   net revenue = rental - paid out + fees; gross profit = net revenue - processing % x (rental + fees)
//   operating   = premium / 12 + (staff + hires started) x growth + (software + marketing + repairs + other) x growth
//   EBITDA      = gross profit - operating; investor returns = investors on file + planned raises past their lockup
//   tax         = max(0, EBITDA - investor returns) x tax rate; cash flow = EBITDA - investor returns - tax + raises - one-time
// An actual month uses its actuals; an operating line with nothing entered in Admin > Expenses for that month uses the
// assumption instead, marked as estimated (blank fleet insurance stays $0 until the premium is entered).
import { daysInMonth, monthlyReturnCents } from '../deck/returns.ts';

export type Cents = number;
export interface Named { label: string; cents: Cents }
export interface ActualMonth {
  month: string;                       // YYYY-MM-01
  complete: boolean;                   // the month has ended (Toronto)
  rental_cents: Cents; rental_insurer_cents: Cents; rental_renter_cents: Cents;
  rented_days: number; rentals: number; cars: number;
  fees_cents: Cents; fees_by_kind: Record<string, Named>;
  cash_by_method: Record<string, { label: string; in_cents: Cents; out_cents: Cents; count: number }>;
  owner_share_cents: Cents; partner_share_cents: Cents; commissions_cents: Cents; kickbacks_cents: Cents; owner_payouts_paid_cents: Cents;
  processing_cents: Cents;
  expenses_cents: Cents; expenses_by_category: Record<string, Named>;
  investor_payouts_cents: Cents; investor_capital_cents: Cents;
  rental_by_segment?: Record<string, Cents>;          // company, shareholder, program, partner
}
export interface Hire { role: string; monthly: number; start: string }            // CAD a month, YYYY-MM
export interface Raise { month: string; amount: number }                           // YYYY-MM, CAD
export interface OneTime { label: string; month: string; amount: number }
export interface Inputs {
  launchMonth: string;                 // YYYY-MM, month 0 of the model
  carsStart: number | null; carsAddedPerMonth: number; addMonths: number;
  utilStart: number | null; utilTarget: number; utilRampMonths: number;
  ratePerDay: number | null; rateGrowth: number;
  feePct: number | null; companyKeepPct: number | null; processingPct: number;
  costGrowth: number;
  staff: number; software: number; marketing: number; repairs: number; other: number;   // CAD a month
  hires: Hire[];
  insurancePremium: number | null;     // CAD a year; blank until the Admin enters it
  raises: Raise[]; investorRate: number; lockupMonths: number;
  taxRate: number;
  openingCash: number; oneTime: OneTime[];
}
export interface InvestorOnFile { invested_cents: Cents; yearly_bps: number; lockup_end_date: string; status: string }

export const DAYS_PER_MONTH = 30.4;
// The workbook's defaults (Company P&L and Forecast inputs): estimates to confirm, never fleet facts.
export const DEFAULT_INPUTS: Inputs = {
  launchMonth: '2026-10', carsStart: null, carsAddedPerMonth: 1, addMonths: 36,
  utilStart: null, utilTarget: 0.55, utilRampMonths: 6,
  ratePerDay: null, rateGrowth: 0.03,
  feePct: null, companyKeepPct: null, processingPct: 0.03,
  costGrowth: 0.03,
  staff: 4329, software: 106, marketing: 500, repairs: 300, other: 400,
  hires: [{ role: 'Field staff 2 (80 hours a month)', monthly: 1440, start: '2027-05' }, { role: 'Customer service VA 2', monthly: 552, start: '2027-11' }],
  insurancePremium: null,
  raises: [], investorRate: 0.3, lockupMonths: 6,
  taxRate: 0.122,
  openingCash: 40000, oneTime: [{ label: 'Franchise fee', month: '2026-10', amount: 35000 }]
};
// When there is no complete actual month yet: the starting points the forecast needs
export const FALLBACK = { cars: 10, util: 0.35, ratePerDay: 100, feePct: 0.1, companyKeepPct: 0.35 };

export const OPEX_LINES = [
  { key: 'insurance', label: 'Fleet insurance', categories: ['fleet_insurance'] },
  { key: 'staff', label: 'Staff and contractors', categories: ['staff'] },
  { key: 'software', label: 'Software', categories: ['software'] },
  { key: 'marketing', label: 'Marketing', categories: ['marketing'] },
  { key: 'repairs', label: 'Repairs and maintenance', categories: ['repair_absorbed'] },
  { key: 'other', label: 'Other (tolls, trackers, parking, towing, other)', categories: ['toll_ticket_absorbed', 'tracker_service', 'other'] }
] as const;
export type OpexKey = (typeof OPEX_LINES)[number]['key'];

export interface ModelMonth {
  month: string; n: number; year: number; kind: 'A' | 'F'; k: number;   // k: months after the base month (0 for actuals)
  cars: number; util: number; ratePerDay: number; rentedDays: number;
  rental: number; fees: number; paidOut: number; netRevenue: number; processing: number; grossProfit: number;
  opex: Record<OpexKey, number>; opexEstimated: OpexKey[]; opexTotal: number;
  ebitda: number; investorReturns: number; tax: number; netIncome: number;
  raises: number; oneTime: number; cashFlow: number; openingCash: number; closingCash: number;
}
export interface Base { month: string | null; cars: number; util: number; ratePerDay: number; feePct: number; companyKeepPct: number; source: Record<string, 'actual' | 'input' | 'fallback'> }
export interface Model { base: Base; months: ModelMonth[]; breakEven: string | null; cashLow: { month: string; cash: number } | null; years: ProFormaYear[]; latestActual: string | null; warnings: string[] }
export interface ProFormaYear { year: number; from: string; to: string; actualMonths: number; rental: number; fees: number; paidOut: number; netRevenue: number; processing: number; grossProfit: number;
  opex: number; ebitda: number; investorReturns: number; tax: number; netIncome: number; raises: number; oneTime: number; cashFlow: number; closingCash: number; carsEnd: number; ebitdaMargin: number }

export const ym = (s: string) => s.slice(0, 7);
export function addYm(key: string, n: number): string { const i = Number(key.slice(0, 4)) * 12 + Number(key.slice(5, 7)) - 1 + n; return `${Math.floor(i / 12)}-${String((i % 12) + 1).padStart(2, '0')}`; }
export function ymDiff(a: string, b: string): number { return (Number(b.slice(0, 4)) - Number(a.slice(0, 4))) * 12 + Number(b.slice(5, 7)) - Number(a.slice(5, 7)); }
const d = (c: Cents) => c / 100;

/** What an actual month says about the base: fleet, utilization, the rate per rented day, the fee and keep percentages. */
export function baseFrom(actuals: ActualMonth[], inp: Inputs): Base {
  const done = actuals.filter((a) => a.complete).sort((a, b) => a.month.localeCompare(b.month));
  const b = done[done.length - 1] ?? null;
  const src: Base['source'] = {};
  const pick = (k: string, input: number | null, actual: number | null, fb: number) => {
    if (input !== null && input !== undefined && Number.isFinite(input)) { src[k] = 'input'; return input; }
    if (actual !== null && Number.isFinite(actual) && actual > 0) { src[k] = 'actual'; return actual; }
    src[k] = 'fallback'; return fb;
  };
  const dim = b ? daysInMonth(Number(b.month.slice(0, 4)), Number(b.month.slice(5, 7))) : 30;
  const rental = b ? d(b.rental_cents) : 0;
  const cars = pick('cars', inp.carsStart, b?.cars ?? null, FALLBACK.cars);
  return {
    month: b ? b.month : null,
    cars,
    util: pick('util', inp.utilStart, b && b.cars > 0 ? b.rented_days / (b.cars * dim) : null, FALLBACK.util),
    ratePerDay: pick('ratePerDay', inp.ratePerDay, b && b.rented_days > 0 ? rental / b.rented_days : null, FALLBACK.ratePerDay),
    feePct: pick('feePct', inp.feePct, b && rental > 0 ? d(b.fees_cents) / rental : null, FALLBACK.feePct),
    companyKeepPct: pick('companyKeepPct', inp.companyKeepPct, b && rental > 0 ? (rental - d(b.owner_share_cents + b.partner_share_cents + b.commissions_cents + b.kickbacks_cents)) / rental : null, FALLBACK.companyKeepPct),
    source: src
  };
}

/** The investors already on file: their Return for each month (the agreement's formula), in dollars. */
export function investorsOnFile(list: InvestorOnFile[], key: string): number {
  const [y, m] = [Number(key.slice(0, 4)), Number(key.slice(5, 7))];
  const dim = daysInMonth(y, m);
  const end = `${key}-${String(dim).padStart(2, '0')}`;
  let c = 0;
  for (const x of list) {
    if (x.status !== 'active' || end < x.lockup_end_date) continue;
    const from = x.lockup_end_date > `${key}-01` ? Number(x.lockup_end_date.slice(8, 10)) : 1;
    c += monthlyReturnCents(x.invested_cents, x.yearly_bps, dim - from + 1, dim);
  }
  return c / 100;
}

export function runModel(actuals: ActualMonth[], inp: Inputs, investors: InvestorOnFile[] = [], horizon = 60): Model {
  const byMonth = new Map(actuals.map((a) => [ym(a.month), a]));
  const base = baseFrom(actuals, inp);
  const baseKey = base.month ? ym(base.month) : null;
  const launch = inp.launchMonth;
  const months: ModelMonth[] = [];
  const warnings: string[] = [];
  if (inp.insurancePremium === null) warnings.push('The fleet insurance premium is blank: it counts as $0, so profit is overstated until it is entered.');
  let cash = inp.openingCash;
  for (let n = 0; n < horizon; n++) {
    const key = addYm(launch, n);
    const year = Math.floor(n / 12) + 1;
    const a = byMonth.get(key);
    const isA = !!a && a.complete && (!baseKey || key <= baseKey);
    const k = baseKey ? Math.max(0, ymDiff(baseKey, key)) : n + 1;
    const g = (r: number) => (1 + r) ** Math.floor(Math.max(0, k - 1) / 12);
    const hires = inp.hires.filter((h) => h.start && h.start <= key).reduce((s, h) => s + (Number(h.monthly) || 0), 0);
    const assumed: Record<OpexKey, number> = {
      insurance: (inp.insurancePremium ?? 0) / 12,
      staff: (inp.staff + hires) * g(inp.costGrowth),
      software: inp.software * g(inp.costGrowth), marketing: inp.marketing * g(inp.costGrowth), repairs: inp.repairs * g(inp.costGrowth), other: inp.other * g(inp.costGrowth)
    };
    const raises = inp.raises.filter((r) => r.month === key).reduce((s, r) => s + (Number(r.amount) || 0), 0);
    const plannedReturns = inp.raises.filter((r) => ymDiff(r.month, key) >= inp.lockupMonths + 1).reduce((s, r) => s + (Number(r.amount) || 0), 0) * inp.investorRate / 12;
    const oneTime = inp.oneTime.filter((o) => o.month === key).reduce((s, o) => s + (Number(o.amount) || 0), 0);
    let m: Omit<ModelMonth, 'tax' | 'netIncome' | 'cashFlow' | 'openingCash' | 'closingCash' | 'ebitda' | 'opexTotal'>;
    if (isA && a) {
      const dim = daysInMonth(Number(key.slice(0, 4)), Number(key.slice(5, 7)));
      const rental = d(a.rental_cents), fees = d(a.fees_cents), paidOut = d(a.owner_share_cents + a.partner_share_cents + a.commissions_cents + a.kickbacks_cents);
      const opex = {} as Record<OpexKey, number>; const est: OpexKey[] = [];
      for (const l of OPEX_LINES) {
        const v = l.categories.reduce((s, c) => s + d(a.expenses_by_category[c]?.cents ?? 0), 0);
        if (v > 0) opex[l.key] = v; else { opex[l.key] = assumed[l.key]; if (assumed[l.key] > 0) est.push(l.key); }
      }
      const netRevenue = rental - paidOut + fees, processing = d(a.processing_cents);
      m = { month: `${key}-01`, n, year, kind: 'A', k: 0, cars: a.cars, util: a.cars > 0 ? a.rented_days / (a.cars * dim) : 0, ratePerDay: a.rented_days > 0 ? rental / a.rented_days : 0,
        rentedDays: a.rented_days, rental, fees, paidOut, netRevenue, processing, grossProfit: netRevenue - processing, opex, opexEstimated: est,
        investorReturns: d(a.investor_payouts_cents), raises: d(a.investor_capital_cents), oneTime };
    } else {
      const cars = base.cars + inp.carsAddedPerMonth * Math.min(k, inp.addMonths);
      const util = base.util + (inp.utilTarget - base.util) * Math.min(1, k / Math.max(1, inp.utilRampMonths));
      const rate = base.ratePerDay * g(inp.rateGrowth);
      const days = cars * util * DAYS_PER_MONTH;
      const rental = days * rate, fees = rental * base.feePct, paidOut = rental * (1 - base.companyKeepPct);
      const netRevenue = rental - paidOut + fees, processing = (rental + fees) * inp.processingPct;
      m = { month: `${key}-01`, n, year, kind: 'F', k, cars, util, ratePerDay: rate, rentedDays: days, rental, fees, paidOut, netRevenue, processing, grossProfit: netRevenue - processing,
        opex: assumed, opexEstimated: [], investorReturns: investorsOnFile(investors, key) + plannedReturns, raises, oneTime };
    }
    const opexTotal = Object.values(m.opex).reduce((s, v) => s + v, 0);
    const ebitda = m.grossProfit - opexTotal;
    const tax = Math.max(0, ebitda - m.investorReturns) * inp.taxRate;
    const netIncome = ebitda - m.investorReturns - tax;
    const cashFlow = netIncome + m.raises - m.oneTime;
    const opening = cash;
    cash += cashFlow;
    months.push({ ...m, opexTotal, ebitda, tax, netIncome, cashFlow, openingCash: opening, closingCash: cash });
  }
  // break-even: the first month from which EBITDA stays at or above zero to the end of the horizon
  let breakEven: string | null = null;
  for (let i = months.length - 1; i >= 0; i--) { if (months[i]!.ebitda >= 0) breakEven = months[i]!.month; else break; }
  const low = months.reduce<{ month: string; cash: number } | null>((lo, x) => (!lo || x.closingCash < lo.cash ? { month: x.month, cash: x.closingCash } : lo), null);
  if (low && low.cash < 0) warnings.push(`Cash goes below zero (lowest ${Math.round(low.cash).toLocaleString('en-CA')} dollars in ${low.month.slice(0, 7)}): plan a raise or cut costs before then.`);
  const years: ProFormaYear[] = [];
  for (let y = 1; y <= Math.ceil(horizon / 12); y++) {
    const ms = months.filter((x) => x.year === y);
    if (!ms.length) continue;
    const s = (f: (x: ModelMonth) => number) => ms.reduce((t, x) => t + f(x), 0);
    const netRevenue = s((x) => x.netRevenue), ebitda = s((x) => x.ebitda);
    years.push({ year: y, from: ms[0]!.month, to: ms[ms.length - 1]!.month, actualMonths: ms.filter((x) => x.kind === 'A').length,
      rental: s((x) => x.rental), fees: s((x) => x.fees), paidOut: s((x) => x.paidOut), netRevenue, processing: s((x) => x.processing), grossProfit: s((x) => x.grossProfit),
      opex: s((x) => x.opexTotal), ebitda, investorReturns: s((x) => x.investorReturns), tax: s((x) => x.tax), netIncome: s((x) => x.netIncome), raises: s((x) => x.raises),
      oneTime: s((x) => x.oneTime), cashFlow: s((x) => x.cashFlow), closingCash: ms[ms.length - 1]!.closingCash, carsEnd: ms[ms.length - 1]!.cars, ebitdaMargin: netRevenue ? ebitda / netRevenue : 0 });
  }
  const latestActual = months.filter((x) => x.kind === 'A').pop()?.month ?? null;
  return { base, months, breakEven, cashLow: low, years, latestActual, warnings };
}

/** Saved assumptions (jsonb) over the defaults, each field checked; anything unreadable keeps its default. */
export function readInputs(saved: unknown): Inputs {
  const s = (saved && typeof saved === 'object' ? saved : {}) as Record<string, unknown>;
  const out: Inputs = { ...DEFAULT_INPUTS, hires: [...DEFAULT_INPUTS.hires], raises: [], oneTime: [...DEFAULT_INPUTS.oneTime] };
  const num = (k: keyof Inputs, nullable = false) => {
    if (!(k in s)) return;
    const v = s[k];
    if (v === null || v === '') { if (nullable) (out as unknown as Record<string, unknown>)[k] = null; return; }
    const n = Number(v);
    if (Number.isFinite(n)) (out as unknown as Record<string, unknown>)[k] = n;
  };
  for (const k of ['carsAddedPerMonth', 'addMonths', 'utilTarget', 'utilRampMonths', 'rateGrowth', 'processingPct', 'costGrowth', 'staff', 'software', 'marketing', 'repairs', 'other', 'investorRate', 'lockupMonths', 'taxRate', 'openingCash'] as const) num(k);
  for (const k of ['carsStart', 'utilStart', 'ratePerDay', 'feePct', 'companyKeepPct', 'insurancePremium'] as const) num(k, true);
  if (typeof s.launchMonth === 'string' && /^\d{4}-\d{2}$/.test(s.launchMonth)) out.launchMonth = s.launchMonth;
  const list = <T,>(k: string, f: (x: Record<string, unknown>) => T | null): T[] | null => Array.isArray(s[k]) ? (s[k] as unknown[]).map((x) => (x && typeof x === 'object' ? f(x as Record<string, unknown>) : null)).filter((x): x is T => x !== null) : null;
  const mon = (v: unknown) => (typeof v === 'string' && /^\d{4}-\d{2}/.test(v) ? v.slice(0, 7) : null);
  const hires = list<Hire>('hires', (x) => { const m = mon(x.start), a = Number(x.monthly); return m && Number.isFinite(a) ? { role: String(x.role ?? 'Hire').slice(0, 80), monthly: a, start: m } : null; });
  if (hires) out.hires = hires;
  const raises = list<Raise>('raises', (x) => { const m = mon(x.month), a = Number(x.amount); return m && Number.isFinite(a) && a > 0 ? { month: m, amount: a } : null; });
  if (raises) out.raises = raises;
  const one = list<OneTime>('oneTime', (x) => { const m = mon(x.month), a = Number(x.amount); return m && Number.isFinite(a) && a > 0 ? { label: String(x.label ?? 'One-time cost').slice(0, 80), month: m, amount: a } : null; });
  if (one) out.oneTime = one;
  return out;
}
