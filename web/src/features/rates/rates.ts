// The rate form's words and number handling (migration 0064), shared by Add a car, a car's Rates tab and Fleet.
// What each rate means is what public.calc_rental_charge() (0003) does with it: each 24 hours from the pickup time is
// one day; a day that starts on a Friday or Saturday (Toronto time) is charged the weekend rate, any other day the
// daily rate; 1 to 6 days never cost more than the weekly rate; 7 to 29 days cost the weekly rate for each 7 days, by
// the day, never more than the monthly rate; 30 days cost the monthly rate.

export type RateKey = 'daily' | 'weekend' | 'weekly' | 'monthly';
export const RATE_FIELDS: Array<{ key: RateKey; label: string; hint: string }> = [
  { key: 'daily', label: 'Daily rate (per day, Sunday to Thursday)', hint: 'Charged for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday. Needed to post the car.' },
  { key: 'weekend', label: 'Weekend rate (per day, Friday and Saturday)', hint: 'A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate. Empty: the daily rate.' },
  { key: 'weekly', label: 'Weekly rate (price for 7 days)', hint: 'Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more. Empty: 6 days at the daily rate.' },
  { key: 'monthly', label: 'Monthly rate (price for 30 days)', hint: 'A 30-day rental costs this, and a 7 to 29 day rental never costs more. Empty: 22 days at the daily rate.' }
];
export const RATE_NAMES: Record<string, string> = {
  daily: 'Daily rate', weekend: 'Weekend rate', weekly: 'Weekly rate', monthly: 'Monthly rate', km_per_day: 'Kilometres included a day',
  overage: 'Extra kilometre rate', deposit: 'Deposit', delivery: 'Delivery fee', pickup: 'Pickup fee', km_mode: 'Kilometres'
};

/** Dollars as typed ("89", "$1,250.50") to whole cents; empty is undefined; anything else is the text itself, which
 *  the database refuses with a message on that field. */
export function toCents(s: string | undefined | null): number | string | undefined {
  const t = (s ?? '').trim();
  if (!t) return undefined;
  const n = t.replace(/[$,\s]/g, '');
  if (!/^-?\d+(\.\d{1,2})?$/.test(n)) return t;
  return Math.round(Number(n) * 100);
}
/** Whole kilometres as typed; empty is undefined; anything else is the text itself. */
export function toKm(s: string | undefined | null): number | string | undefined {
  const t = (s ?? '').trim().replace(/[,\s]/g, '');
  if (!t) return undefined;
  return /^-?\d+$/.test(t) ? Number(t) : t;
}
/** Cents to what the input shows: 8900 is "89", 8950 is "89.50", nothing is "". */
export function centsInput(c: unknown): string {
  if (c === null || c === undefined || c === '') return '';
  const n = Number(c);
  if (!Number.isFinite(n)) return '';
  return n % 100 === 0 ? String(n / 100) : (n / 100).toFixed(2);
}

export type RateValues = Record<string, string>;
/** What the database's check and save take (app.rate_card_check): cents, kilometres and the kilometre choice. */
export function ratePayload(v: RateValues, o: { delivery?: boolean } = {}): Record<string, unknown> {
  const p: Record<string, unknown> = {
    daily: toCents(v.daily), weekend: toCents(v.weekend), weekly: toCents(v.weekly), monthly: toCents(v.monthly),
    km_mode: v.km_mode === 'custom' ? 'custom' : 'default', deposit: toCents(v.deposit)
  };
  if (v.km_mode === 'custom') { p.km_per_day = toKm(v.km_per_day); p.overage = toCents(v.overage); }
  if (o.delivery) { p.delivery = toCents(v.delivery); p.pickup = toCents(v.pickup); }
  return p;
}
/** True when nothing about the rates was typed (Add a car: the rates may wait). */
export const ratesEmpty = (v: RateValues) => !['daily', 'weekend', 'weekly', 'monthly'].some((k) => (v[k] ?? '').trim());

export type Example = { code: string; label: string; days: number; cents: number; km_included: number; text: string; rate_applied: string };
export type RateCheck = {
  ok: boolean; errors: Record<string, string>; messages: string[]; warnings: string[]; derived: string[];
  values: Record<string, number | string | boolean | null>; examples: Example[]; km_text: string | null;
  defaults: { class: string; km_per_day: number; overage_cents: number | null; overage_min_cents: number | null; overage_max_cents: number | null; deposit_cents: number | null;
    km_choices: number[]; deposit_tiers: Array<{ amount_cents: number; label: string }>; text: string;
    suggestion: { daily_cents: number; weekend_cents: number; weekly_cents: number; monthly_cents: number; cars: number; basis: string; text: string } | null;
    /** 0070: the daily rate a new car starts from (similar cars, else Program settings by class) */
    daily_default_cents?: number | null; daily_default_text?: string | null };
};
