// The car search: the filters of the site's /cars page, on the phone. The server gives every listed car once
// (GET /cars) and, for chosen dates, which are free with their price (POST /cars/available); everything else is here.
// Models are shown by family ("C-Class" with its trims under it), the same rule as the site (web/src/features/vin).
import { familyTree, modelFamily, type Available, type CarCard } from '../shared.ts';

export interface Filters { classes: string[]; seats: number | null; make: string | null; family: string | null; trim: string | null; transmission: 'automatic' | 'manual' | null; maxDailyCents: number | null }
export const noFilters = (): Filters => ({ classes: [], seats: null, make: null, family: null, trim: null, transmission: null, maxDailyCents: null });
export type Sort = 'recommended' | 'price_low' | 'price_high';
export interface Hit { car: CarCard; family: string; quote: Available | null }

export function familyOf(c: Pick<CarCard, 'make' | 'model' | 'trim'>): { model: string; trim: string | null } {
  const f = modelFamily(c.make, c.model, c.trim ?? null);
  return { model: f.model, trim: f.trim };
}
/** The makes on offer and, for the chosen make, its model families with their trims. */
export function makeOptions(cars: readonly CarCard[], make: string | null): { makes: string[]; families: Array<{ model: string; trims: string[] }> } {
  const makes = [...new Set(cars.map((c) => c.make))].sort((a, b) => a.localeCompare(b));
  const tree = familyTree(cars.filter((c) => !make || c.make === make).map((c) => ({ make: c.make, model: c.model, trim: c.trim ?? null })));
  return { makes, families: make ? tree.find((t) => t.make === make)?.families ?? [] : [] };
}
/** How many filters are set (the badge on the Filters button). */
export const activeCount = (f: Filters) => f.classes.length + [f.seats, f.make, f.family, f.transmission, f.maxDailyCents].filter((x) => x !== null).length;

/**
 * The cars to show. With dates chosen (`available` not null) only the free cars, each with its quote; a car the server
 * did not return for the dates is left out. The daily rate filter uses the quote's rate when there is one.
 */
export function searchCars(cars: readonly CarCard[], f: Filters, available: readonly Available[] | null, sort: Sort = 'recommended'): Hit[] {
  const quotes = available ? new Map(available.map((a) => [a.vehicle_id, a])) : null;
  const hits: Hit[] = [];
  for (const car of cars) {
    const quote = quotes?.get(car.vehicle_id) ?? null;
    if (quotes && !quote) continue;
    const fam = familyOf(car);
    if (f.classes.length && !f.classes.some((c) => car.classes.includes(c))) continue;
    if (f.seats !== null && (car.seats ?? 0) < f.seats) continue;
    if (f.make && car.make !== f.make) continue;
    if (f.family && fam.model !== f.family) continue;
    if (f.trim && fam.trim !== f.trim) continue;
    if (f.transmission && (car.transmission ?? '').toLowerCase() !== f.transmission) continue;
    if (f.maxDailyCents !== null && (quote?.daily_rate_cents ?? car.daily_rate_cents) > f.maxDailyCents) continue;
    hits.push({ car, family: fam.model, quote });
  }
  const rate = (h: Hit) => h.quote?.daily_rate_cents ?? h.car.daily_rate_cents;
  if (sort === 'price_low') hits.sort((a, b) => rate(a) - rate(b));
  if (sort === 'price_high') hits.sort((a, b) => rate(b) - rate(a));
  return hits;
}
/** Dates the search can ask about: a pickup today or later (Toronto), a return after it, within the longest rental. */
export function datesProblem(from: string | null, to: string | null, today: string, maxDays: number): string | null {
  if (!from || !to) return null;
  if (from < today) return 'The pickup date has passed.';
  if (to <= from) return 'The return date must be after the pickup date.';
  const days = Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400_000);
  if (days > maxDays) return `The longest rental is ${maxDays} days.`;
  return null;
}
