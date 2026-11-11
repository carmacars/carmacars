// Demand steering on the search pages (release 36, part 8; migration 2000): a car that draws more than its share of
// the requests (app.fleet_trend.popular) goes after the others in every similar-car list, and the similar cars a page
// shows rotate by the page, so the pages of one class do not all send their readers to the same few cars. Pure.

export interface Steerable { vehicle_id?: string | null; popular?: boolean | null }

/** The cars with the popular ones last (the order is kept otherwise). */
export function steer<T extends Steerable>(cars: T[], popularIds: readonly string[] = []): T[] {
  const pop = new Set(popularIds);
  const isPop = (c: T) => !!c.popular || (!!c.vehicle_id && pop.has(c.vehicle_id));
  return [...cars.filter((c) => !isPop(c)), ...cars.filter(isPop)];
}

/** A small stable hash of a page's address (FNV-1a). */
export function pageHash(key: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < key.length; i++) { h ^= key.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h >>> 0;
}

/** n similar cars for a page: the closest `pool` candidates (already ranked), steered, then rotated by the page's
 *  address so each page of the same kind starts at a different car. Deterministic: a page's list changes only when
 *  the fleet does (the cached copy stays valid). */
export function pickSimilar<T extends Steerable>(ranked: T[], n: number, key: string, popularIds: readonly string[] = [], pool = n * 3): T[] {
  const cand = steer(ranked.slice(0, Math.max(pool, n)), popularIds);
  const fresh = cand.filter((c) => !(c.popular || (c.vehicle_id && popularIds.includes(c.vehicle_id))));
  if (fresh.length <= n) return [...fresh, ...cand.filter((c) => !fresh.includes(c))].slice(0, n);
  // the closest car always stays; the rest rotate within the closest pool
  const [first, ...rest] = fresh;
  const k = pageHash(key) % rest.length;
  return [first!, ...rest.slice(k), ...rest.slice(0, k)].slice(0, n);
}
