import type { MapsAdapter, Place, PlaceSuggestion } from './types';
import type { AddressParts } from '../../features/forms/address-parts.ts';

// r36 (migration 2120): the site's own Canadian address database (Statistics Canada's Open Database of Addresses, loaded by
// the addresses workflow) in front of the maps adapter. Suggestions come from the database first; only when it has nothing
// (an address not in the ODA, a place name, a street without its number, an address abroad) is the adapter behind asked:
// Google when a key is configured (within its daily cap, budget.ts), else the sample landmarks. A chosen database address
// ("ca-<n>") is read from the database, never sent to Google. Pure: the database calls are passed in (index.ts), tested in
// address-book.test.ts. A database that cannot be read leaves the adapter behind to answer, as before.
export interface AddressDb {
  search(q: string, limit: number): Promise<PlaceSuggestion[]>;
  get(id: string): Promise<{ id: string; label: string; lat: number | null; lng: number | null; parts: AddressParts } | null>;
}
export const OWN_ID = /^ca-\d{1,18}$/;

export function addressBook(inner: MapsAdapter, db: AddressDb, limit = 6): MapsAdapter {
  const own = async (q: string): Promise<PlaceSuggestion[]> => {
    if (q.trim().length < 4 || !/^\s*\d/.test(q)) return [];
    try { return await db.search(q, limit); } catch { return []; }
  };
  return {
    name: inner.name,
    async autocomplete(query, sessionToken, o) {
      const mine = await own(query);
      return mine.length ? mine : inner.autocomplete(query, sessionToken, o);
    },
    async suggest(query, sessionToken, o) {
      const mine = await own(query);
      if (mine.length) return { items: mine, limited: false };
      return inner.suggest ? inner.suggest(query, sessionToken, o) : { items: await inner.autocomplete(query, sessionToken, o), limited: false };
    },
    async place(id, sessionToken): Promise<Place | null> {
      if (!OWN_ID.test(id)) return inner.place(id, sessionToken);
      const a = await db.get(id).catch(() => null);
      if (!a) return null;
      // a database address without its point: the distance is worked out later ("to be confirmed"), as for a place with none
      return { id: a.id, label: a.label, lat: a.lat ?? Number.NaN, lng: a.lng ?? Number.NaN, parts: a.parts };
    },
    async distanceKm(from, to) {
      if (![from.lat, from.lng, to.lat, to.lng].every(Number.isFinite)) return null;
      return inner.distanceKm(from, to);
    }
  };
}
