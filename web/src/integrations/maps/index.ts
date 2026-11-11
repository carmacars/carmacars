import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { MapsAdapter } from './types';
import { fakeMaps } from './fake';
import { budgetedMaps, type MapsSku } from './budget';
import { addressBook, type AddressDb } from './address-book';

// MAPS_PROVIDER=google with a GOOGLE_MAPS_API_KEY (the deploy job sets both when the vault holds
// deploy_google_maps_api_key); anything else, or no key, is the fake adapter (sample Toronto places,
// straight-line distance), so the site never breaks for want of a key. Google calls are capped a day per SKU (0113,
// budget.ts): over the cap, or with the database unreachable, the answer is as if Google had nothing.
let cached: MapsAdapter | undefined;
export async function maps(): Promise<MapsAdapter> {
  if (cached) return cached;
  const e = env();
  if (e.MAPS_PROVIDER === 'google' && e.GOOGLE_MAPS_API_KEY) {
    const { googleMaps } = await import('./google');
    cached = budgetedMaps(googleMaps(e.GOOGLE_MAPS_API_KEY), fakeMaps(), takeBudget);
  } else {
    // production without a key: the address fields only know the sample Toronto landmarks; said once in the log
    if (e.APP_ENV === 'production') console.warn(`maps: the fake adapter is in use (MAPS_PROVIDER=${e.MAPS_PROVIDER}, key ${e.GOOGLE_MAPS_API_KEY ? 'set' : 'missing'}): address suggestions are the sample landmarks only`);
    cached = fakeMaps();
  }
  // r36 (2120): the site's own Canadian address database first; Google (or the sample landmarks) only when it has nothing
  cached = addressBook(cached, addressDb);
  return cached;
}

const SR = { role: 'service_role' as const };
const addressDb: AddressDb = {
  search: async (q, limit) => ((await rpc('server_address_search', { p_q: q, p_limit: limit }, SR)) as unknown as Array<{ id: string; label: string }> | null) ?? [],
  get: async (id) => (await rpc('server_address_get', { p_id: id }, SR)) as unknown as Awaited<ReturnType<AddressDb['get']>>
};

async function takeBudget(sku: MapsSku): Promise<boolean> {
  return (await rpc('server_maps_take', { p_sku: sku }, { role: 'service_role' })) === true;
}
export type * from './types';
