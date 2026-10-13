import 'server-only';
import { env } from '@/lib/env';
import type { MapsAdapter } from './types';
import { fakeMaps } from './fake';

// MAPS_PROVIDER=google with a GOOGLE_MAPS_API_KEY (the deploy job sets both when the vault holds
// deploy_google_maps_api_key); anything else, or no key, is the fake adapter (sample Toronto places,
// straight-line distance), so the site never breaks for want of a key.
let cached: MapsAdapter | undefined;
export async function maps(): Promise<MapsAdapter> {
  if (cached) return cached;
  const e = env();
  if (e.MAPS_PROVIDER === 'google' && e.GOOGLE_MAPS_API_KEY) {
    const { googleMaps } = await import('./google');
    cached = googleMaps(e.GOOGLE_MAPS_API_KEY);
  } else cached = fakeMaps();
  return cached;
}
export type * from './types';
