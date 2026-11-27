// The earnings calculator of List your car and the application (migrations 0354, 3291, 5141): pure maths over the small set
// of numbers public.owner_calc_data returns with the page. 5141 (the owner, Nov 27): the owner's rule sets the month. At the
// occupancy of Program settings (80%) a typical car makes the typical month for its owner ($1,200), never under the floor
// ($800), more for a newer car or a class in higher demand. An old car of a premium make is not priced as premium. The days
// slider, the owner's share and the season move that month; nothing here is a price, every number is a Program setting.

export interface CalcClass { code: string; label: string; card_cents: number | null; avg_cents: number | null; n: number }
export interface CalcModel { make: string; model: string; class: string; avg_cents: number; n: number; years?: { year: number; avg_cents: number; n: number }[]; avg_year?: number | null }
export interface CalcRule { make: string | null; model_re: string | null; trim_re: string | null; body_re: string | null; class: string; aged_years: number | null; aged_class: string | null }
/** 5141: the owner's rule, from Program settings. */
export interface CalcTarget { typical_cents: number; floor_cents: number; occupancy_pct: number; typical_age: number; age_step_pct: number; premium_max_age: number; class_factor: Record<string, number> }
export interface CalcData { classes: CalcClass[]; models: CalcModel[]; rules: CalcRule[]; fees: { insurance_cents: number | null; tracker_cents: number | null }; year: number;
  /** 3291: the season (the factor of each month, jan .. dec) and the percent off the listed rate on a rented day */
  season?: Record<string, number>; base_days?: number; discount_pct?: number; target?: CalcTarget }
export interface CalcCar { year?: number | null; make?: string | null; model?: string | null; trim?: string | null; body?: string | null }

/** The Program settings' defaults (5141), only until the page has them. */
export const TARGET: CalcTarget = { typical_cents: 120000, floor_cents: 80000, occupancy_pct: 80, typical_age: 5, age_step_pct: 5, premium_max_age: 8,
  class_factor: { economy: 0.9, standard: 1, sedan: 1, coupe: 1.05, van: 1.05, pickup: 1.05, suv: 1.1, premium: 1.15, convertible: 1.2, luxury: 1.3, exotic: 1.8 } };
/** The days slider: rented days of an average month (a car is never out every day: cleaning, service, gaps). */
export const DAYS = { min: 4, max: 26 } as const;
export const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'] as const;
export const MONTH_NAME = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'] as const;
const MONTH_DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
/** The GTA's rental year when the page has no setting yet: summer busiest, winter slow, the shoulder months slowest. */
export const SEASON: Record<string, number> = { jan: 0.75, feb: 0.75, mar: 0.70, apr: 0.65, may: 0.85, jun: 1.10, jul: 1.30, aug: 1.30, sep: 0.85, oct: 0.70, nov: 0.65, dec: 0.85 };
/** The days the slider starts at: the occupancy of a 30-day month (80%: 24 days). */
export const occupancyDays = (d: Pick<CalcData, 'target'> | null | undefined) => Math.min(DAYS.max, Math.max(DAYS.min, Math.round(((d?.target ?? TARGET).occupancy_pct * 30) / 100)));
/** The owner's share the typical month is at; the slider moves it. */
export const SHARE = { min: 60, max: 90, start: 70 } as const;

/** The make as the class rules key it (app.make_key): lower case letters and digits only. */
export const makeKey = (m: string | null | undefined) => (m ?? '').toLowerCase().replace(/[^a-z0-9]/g, '') || null;

// a rule's regular expression, read as Postgres reads it (case-insensitive; \m and \M are word edges)
const re = (p: string) => { try { return new RegExp(p.replace(/\\[mM]/g, '\\b'), 'i'); } catch { return null; } };
const fits = (p: string | null, v: string | null | undefined) => p === null || !!re(p)?.test(v ?? '');

/** The class a car gets when it is added (app.infer_vehicle_class): the first rule that fits, aged down when old. */
export function classOf(rules: CalcRule[], car: CalcCar, year: number): string {
  const mk = makeKey(car.make);
  const r = rules.find((x) => (x.make === null || x.make === mk) && fits(x.model_re, car.model) && fits(x.trim_re, car.trim) && fits(x.body_re, car.body));
  if (!r) return 'standard';
  const age = car.year && car.year > 1900 ? year - car.year : null;
  return r.aged_years !== null && r.aged_class && age !== null && age >= r.aged_years ? r.aged_class : r.class;
}

const PREMIUM = new Set(['premium', 'luxury', 'exotic']);
/** 5141: the class the calculator prices: the car's class, but a premium or luxury make older than premium_max_age years is
 *  priced as the car under the make (the rules without a make: its body), else standard. */
export function calcClass(d: CalcData, car: CalcCar): string {
  const t = d.target ?? TARGET;
  const c = classOf(d.rules, car, d.year);
  const age = car.year && car.year > 1900 ? d.year - car.year : null;
  if (!PREMIUM.has(c) || age === null || age <= t.premium_max_age) return c;
  const under = classOf(d.rules.filter((r) => r.make === null), car, d.year);
  return PREMIUM.has(under) ? 'standard' : under;
}

export interface MonthAt { cents: number; cls: string; label: string; age: number | null; ageFactor: number; demand: number; floored: boolean }
/** 5141: the owner's month at the occupancy and the typical share: typical x age factor x demand, never under the floor. */
export function monthlyAt(d: CalcData, car: CalcCar): MonthAt {
  const t = d.target ?? TARGET;
  const cls = calcClass(d, car);
  const label = d.classes.find((x) => x.code === cls)?.label ?? cls.charAt(0).toUpperCase() + cls.slice(1);
  const age = car.year && car.year > 1900 ? Math.max(0, d.year - car.year) : null;
  const ageFactor = Math.min(1.3, Math.max(0.5, 1 + ((t.typical_age - (age ?? t.typical_age)) * t.age_step_pct) / 100));
  const demand = Number(t.class_factor[cls]) > 0 ? Number(t.class_factor[cls]) : 1;
  const raw = Math.round(t.typical_cents * ageFactor * demand);
  return { cents: Math.max(t.floor_cents, raw), cls, label, age, ageFactor, demand, floored: raw < t.floor_cents };
}

export interface SeasonMonth { key: string; name: string; factor: number; days: number; revenue: number; share: number; net: number }
export interface SeasonEstimate {
  months: SeasonMonth[];
  /** the twelve months added up, and their average (what the page leads with) */
  yearly: number; average: number; revenueAverage: number; shareAverage: number;
  slow: SeasonMonth; busy: SeasonMonth; fees: number | null; beforeFees: boolean;
  /** the listed daily rate the month implies (after the typical discount comes off a rented day) */
  listedCents: number; discountPct: number;
  /** months in which the share does not cover the monthly fees */
  short: number;
}
/**
 * A year, month by month (5141): the owner's share of an average month is the month at the occupancy, scaled by the days
 * chosen against the occupancy's days and by the share chosen against the typical share; each month moves with the season
 * (its factor against the season's average), never more rented days than the month has nor more than 26. Revenue is the
 * share over the share percent. Cents; the averages are whole dollars.
 */
export function estimate(a: { at: number; days: number; occupancyDays: number; sharePct: number; fees: CalcData['fees']; season?: Record<string, number> | null; discountPct?: number | null }): SeasonEstimate {
  const pct = Math.min(100, Math.max(1, a.sharePct));
  const discountPct = Math.min(60, Math.max(0, a.discountPct ?? 15));
  const set = a.fees.insurance_cents !== null && a.fees.tracker_cents !== null;
  const fees = set ? (a.fees.insurance_cents ?? 0) + (a.fees.tracker_cents ?? 0) : null;
  const season = a.season ?? SEASON;
  const factors = MONTHS.map((k) => (Number(season[k]) > 0 ? Number(season[k]) : 1));
  const days = Math.max(0, a.days);
  const shareMonth = (a.at * (days / Math.max(1, a.occupancyDays)) * pct) / SHARE.start;
  // the year's rented days (twelve average months) spread over the season, no month above its cap: a busy month that would
  // pass the cap gives its extra days to the others, so the year still averages the days chosen
  const caps = MONTH_DAYS.map((n) => Math.min(n, 26));
  const total = Math.min(days * 12, caps.reduce((n, x) => n + x, 0));
  const spread: number[] = new Array(12).fill(0);
  let open = MONTHS.map((_, i) => i); let left = total;
  for (let pass = 0; pass < 12 && open.length && left > 0; pass++) {
    const w = open.reduce((n, i) => n + factors[i]!, 0);
    const over = open.filter((i) => (left * factors[i]!) / w > caps[i]!);
    if (!over.length) { for (const i of open) spread[i] = (left * factors[i]!) / w; break; }
    for (const i of over) { spread[i] = caps[i]!; left -= caps[i]!; }
    open = open.filter((i) => !over.includes(i));
  }
  const months = MONTHS.map((key, i) => {
    const factor = factors[i]!;
    const share = days > 0 ? Math.round((shareMonth * spread[i]!) / days) : 0;
    const revenue = Math.round((share * 100) / pct);
    return { key, name: MONTH_NAME[i]!, factor, days: Math.round(spread[i]!), revenue, share, net: fees === null ? share : share - fees };
  });
  const sum = (f: (m: SeasonMonth) => number) => months.reduce((n, m) => n + f(m), 0);
  const yearly = sum((m) => m.net);
  const by = [...months].sort((x, y) => x.net - y.net || x.factor - y.factor || MONTHS.indexOf(x.key as never) - MONTHS.indexOf(y.key as never));
  const whole = (c: number) => Math.round(c / 100) * 100;
  const perDay = a.occupancyDays > 0 ? (a.at * 100) / SHARE.start / a.occupancyDays : 0;
  return { months, yearly: whole(yearly), average: whole(yearly / 12), revenueAverage: whole(sum((m) => m.revenue) / 12), shareAverage: whole(sum((m) => m.share) / 12),
    slow: by[0]!, busy: by[by.length - 1]!, fees, beforeFees: fees === null, listedCents: whole(perDay / (1 - discountPct / 100)), discountPct,
    short: fees === null ? 0 : months.filter((m) => m.net < 0).length };
}
