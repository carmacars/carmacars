import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { MapsAdapter } from './types';
import { fakeMaps } from './fake';
import { budgetedMaps, type MapsSku } from './budget';

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
  } else cached = fakeMaps();
  return cached;
}

async function takeBudget(sku: MapsSku): Promise<boolean> {
  return (await rpc('server_maps_take', { p_sku: sku }, { role: 'service_role' })) === true;
}
export type * from './types';
