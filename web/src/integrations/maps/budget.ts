import type { MapsAdapter } from './types';

// The daily cap on Google calls (migration 0113): before each request to Google one call is taken from that SKU's
// budget for the Toronto day (public.server_maps_take). Over the cap, or when the budget cannot be read (the database
// unreachable: treated as over, so Google is never called blind), the call is not made and the answer is the one
// the site already handles without Google: no suggestions (the person types the address), no place (distance "to be
// confirmed"), the straight-line distance estimate (the fake adapter's). The site never breaks for want of budget.
// Pure: the budget check is passed in (index.ts reads it from the database); tested in budget.test.ts.

export type MapsSku = 'autocomplete' | 'place_details' | 'routes';
export type TakeBudget = (sku: MapsSku) => Promise<boolean>;

/** Shortest input sent to Google for suggestions (the form asks only from 3 characters too). */
export const MIN_QUERY = 3;
/** A Google place id as Place Details accepts it (google.ts checks the same before calling). */
export const PLACE_ID = /^[A-Za-z0-9_-]{4,300}$/;

export function budgetedMaps(google: MapsAdapter, fallback: MapsAdapter, take: TakeBudget): MapsAdapter {
  // why a lookup did not reach Google goes to the Worker's log, once per SKU and reason in an isolate's day, so a
  // "suggestions do not work" report can be read in Workers Observability (2026-10-24)
  const said = new Set<string>();
  const say = (sku: MapsSku, why: string) => {
    const k = `${new Date().toISOString().slice(0, 10)}:${sku}:${why.slice(0, 40)}`;
    if (said.has(k)) return; said.add(k);
    console.warn(`maps: ${sku} not sent to Google: ${why}`);
  };
  const allowed = async (sku: MapsSku) => {
    try {
      const ok = (await take(sku)) === true;
      if (!ok) say(sku, 'the daily cap is reached (Admin > Settings > Program, maps_daily_cap_*)');
      return ok;
    } catch (e) { say(sku, `the daily cap could not be read (${e instanceof Error ? e.message : String(e)})`); return false; }
  };
  return {
    name: google.name,
    async autocomplete(query, sessionToken, o) {
      if (query.trim().length < MIN_QUERY) return [];
      return (await allowed('autocomplete')) ? google.autocomplete(query, sessionToken, o) : [];
    },
    async suggest(query, sessionToken, o) {
      if (query.trim().length < MIN_QUERY) return { items: [], limited: false };
      if (!(await allowed('autocomplete'))) return { items: [], limited: true };
      return { items: await google.autocomplete(query, sessionToken, o), limited: false };
    },
    async place(id, sessionToken) {
      if (!PLACE_ID.test(id)) return null;
      return (await allowed('place_details')) ? google.place(id, sessionToken) : null;
    },
    async distanceKm(from, to) {
      return (await allowed('routes')) ? google.distanceKm(from, to) : fallback.distanceKm(from, to);
    }
  };
}
