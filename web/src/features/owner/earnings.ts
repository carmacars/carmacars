// The earnings calculator of List your car (migration 0354, docs/changes/2026-11-06-owner-earnings-calculator.md): pure
// maths over the small set of numbers public.owner_calc_data returns with the page. No price is written here: the daily
// rate is the average of the real cars on the site of the same make and model, else of the same class, else the class
// rate card of Program settings; the fees are Program settings, or "quoted in your agreement" when not set.

export interface CalcClass { code: string; label: string; card_cents: number | null; avg_cents: number | null; n: number }
export interface CalcModel { make: string; model: string; class: string; avg_cents: number; n: number }
export interface CalcRule { make: string | null; model_re: string | null; trim_re: string | null; body_re: string | null; class: string; aged_years: number | null; aged_class: string | null }
export interface CalcData { classes: CalcClass[]; models: CalcModel[]; rules: CalcRule[]; fees: { insurance_cents: number | null; tracker_cents: number | null }; year: number }
export interface CalcCar { year?: number | null; make?: string | null; model?: string | null; trim?: string | null; body?: string | null }

export const DAYS = { min: 5, max: 28, start: 18, low: 5 } as const;
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

export interface Estimate { revenue: number; share: number; fees: number | null; net: number; yearly: number; beforeFees: boolean }
/** A month: the rate times the days, the owner's share of it, less the monthly fees when they are set. Cents. */
export function estimate(a: { rateCents: number; days: number; sharePct: number; fees: CalcData['fees'] }): Estimate {
  const days = Math.min(DAYS.max, Math.max(0, Math.round(a.days)));
  const pct = Math.min(100, Math.max(0, a.sharePct));
  const revenue = Math.round(a.rateCents * days);
  const share = Math.round((revenue * pct) / 100);
  const set = a.fees.insurance_cents !== null && a.fees.tracker_cents !== null;
  const fees = set ? (a.fees.insurance_cents ?? 0) + (a.fees.tracker_cents ?? 0) : null;
  const net = fees === null ? share : share - fees;
  // the year is twelve of the month as shown (whole dollars), so the two numbers on the page always agree
  return { revenue, share, fees, net, yearly: Math.round(net / 100) * 100 * 12, beforeFees: fees === null };
}
