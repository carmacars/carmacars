// The earnings calculator of List your car (migration 0354, docs/changes/2026-11-06-owner-earnings-calculator.md): pure
// maths over the small set of numbers public.owner_calc_data returns with the page. No price is written here: the daily
// rate is the average of the real cars on the site of the same make and model, else of the same class, else the class
// rate card of Program settings; the fees are Program settings, or "quoted in your agreement" when not set.

export interface CalcClass { code: string; label: string; card_cents: number | null; avg_cents: number | null; n: number }
export interface CalcModel { make: string; model: string; class: string; avg_cents: number; n: number }
export interface CalcRule { make: string | null; model_re: string | null; trim_re: string | null; body_re: string | null; class: string; aged_years: number | null; aged_class: string | null }
export interface CalcData { classes: CalcClass[]; models: CalcModel[]; rules: CalcRule[]; fees: { insurance_cents: number | null; tracker_cents: number | null }; year: number;
  /** 3291: the calculator's own season (the factor of each month, jan .. dec), the rented days of an average month it starts
   *  from, and the percent off the listed rate on a rented day. Program settings; the fallbacks below only until the page has them. */
  season?: Record<string, number>; base_days?: number; discount_pct?: number }
export interface CalcCar { year?: number | null; make?: string | null; model?: string | null; trim?: string | null; body?: string | null }

// r48 ops (3291): conservative. The slider is the rented days of an AVERAGE month and stops at 22 (a car is never out
// every day: cleaning, service, gaps between renters); it starts from Program settings (12), not from 18.
export const DAYS = { min: 4, max: 22, start: 12, low: 5 } as const;
export const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'] as const;
export const MONTH_NAME = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'] as const;
const MONTH_DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
/** The GTA's rental year as the calculator reads it when the page has no setting yet: summer busiest, winter slow, the
 *  shoulder months slowest (the same numbers as the Program setting's default). */
export const SEASON: Record<string, number> = { jan: 0.75, feb: 0.75, mar: 0.70, apr: 0.65, may: 0.85, jun: 1.10, jul: 1.30, aug: 1.30, sep: 0.85, oct: 0.70, nov: 0.65, dec: 0.85 };
export const startDays = (d: Pick<CalcData, 'base_days'> | null | undefined) => Math.min(DAYS.max, Math.max(DAYS.min, Math.round(d?.base_days ?? DAYS.start)));
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

export type RateSource = 'model' | 'class' | 'card' | 'none';
/** The daily rate: the same make and model on the site, else the class average, else the class rate card. */
export function rateFor(d: CalcData, car: CalcCar): { cents: number | null; source: RateSource; cls: string; label: string; n: number } {
  const cls = classOf(d.rules, car, d.year);
  const c = d.classes.find((x) => x.code === cls);
  const label = c?.label ?? cls;
  const mk = makeKey(car.make), md = (car.model ?? '').trim().toLowerCase();
  if (mk && md) {
    const m = d.models.find((x) => x.make === mk && x.model === md) ?? d.models.find((x) => x.make === mk && (md.startsWith(x.model + ' ') || x.model.startsWith(md + ' ')));
    if (m && m.avg_cents > 0) return { cents: Math.round(m.avg_cents), source: 'model', cls, label, n: m.n };
  }
  if (c?.avg_cents && c.n > 0) return { cents: Math.round(c.avg_cents), source: 'class', cls, label, n: c.n };
  if (c?.card_cents) return { cents: c.card_cents, source: 'card', cls, label, n: 0 };
  return { cents: null, source: 'none', cls, label, n: 0 };
}

export interface SeasonMonth { key: string; name: string; factor: number; days: number; revenue: number; share: number; net: number }
export interface SeasonEstimate {
  months: SeasonMonth[];
  /** the twelve months added up, and their average (what the page leads with: never twelve of the best month) */
  yearly: number; average: number; revenueAverage: number; shareAverage: number;
  slow: SeasonMonth; busy: SeasonMonth; fees: number | null; beforeFees: boolean;
  /** the daily rate the months are worked at: the listed rate less the typical discount */
  dayCents: number; discountPct: number;
  /** months in which the share does not cover the monthly fees */
  short: number;
}
/**
 * A year, month by month (3291): a month's rented days are the average month's days times the month's factor (never more
 * than the month has, never more than 26: a car is not out every day); each day earns the listed rate less the typical
 * discount; the owner's share of that, less the monthly fees when they are set. Cents; the average is whole dollars.
 */
export function seasonal(a: { rateCents: number; days: number; sharePct: number; fees: CalcData['fees']; season?: Record<string, number> | null; discountPct?: number | null }): SeasonEstimate {
  const base = Math.min(DAYS.max, Math.max(0, Math.round(a.days)));
  const pct = Math.min(100, Math.max(0, a.sharePct));
  const discountPct = Math.min(60, Math.max(0, a.discountPct ?? 15));
  const dayCents = Math.round((a.rateCents * (100 - discountPct)) / 100);
  const set = a.fees.insurance_cents !== null && a.fees.tracker_cents !== null;
  const fees = set ? (a.fees.insurance_cents ?? 0) + (a.fees.tracker_cents ?? 0) : null;
  const season = a.season ?? SEASON;
  const months = MONTHS.map((key, i) => {
    const factor = Number(season[key]) > 0 ? Number(season[key]) : 1;
    const days = Math.min(MONTH_DAYS[i]!, 26, Math.round(base * factor));
    const revenue = dayCents * days;
    const share = Math.round((revenue * pct) / 100);
    return { key, name: MONTH_NAME[i]!, factor, days, revenue, share, net: fees === null ? share : share - fees };
  });
  const sum = (f: (m: SeasonMonth) => number) => months.reduce((n, m) => n + f(m), 0);
  const yearly = sum((m) => m.net);
  const by = [...months].sort((x, y) => x.net - y.net || x.factor - y.factor || MONTHS.indexOf(x.key as never) - MONTHS.indexOf(y.key as never));
  const whole = (c: number) => Math.round(c / 100) * 100;
  return { months, yearly: whole(yearly), average: whole(yearly / 12), revenueAverage: whole(sum((m) => m.revenue) / 12), shareAverage: whole(sum((m) => m.share) / 12),
    slow: by[0]!, busy: by[by.length - 1]!, fees, beforeFees: fees === null, dayCents, discountPct, short: fees === null ? 0 : months.filter((m) => m.net < 0).length };
}
