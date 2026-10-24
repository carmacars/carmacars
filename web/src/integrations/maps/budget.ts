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
  const allowed = async (sku: MapsSku) => {
    try { return (await take(sku)) === true; } catch { return false; }
  };
  return {
    name: google.name,
    async autocomplete(query, sessionToken) {
      if (query.trim().length < MIN_QUERY) return [];
      return (await allowed('autocomplete')) ? google.autocomplete(query, sessionToken) : [];
    },
    async suggest(query, sessionToken) {
      if (query.trim().length < MIN_QUERY) return { items: [], limited: false };
      if (!(await allowed('autocomplete'))) return { items: [], limited: true };
      return { items: await google.autocomplete(query, sessionToken), limited: false };
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
