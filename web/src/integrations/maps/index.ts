import 'server-only';
import { env, required } from '@/lib/env';
import type { MapsAdapter } from './types';
import { fakeMaps } from './fake';

let cached: MapsAdapter | undefined;
export async function maps(): Promise<MapsAdapter> {
  if (cached) return cached;
  if (env().MAPS_PROVIDER === 'google') {
    const { googleMaps } = await import('./google');
    cached = googleMaps(required('GOOGLE_MAPS_API_KEY'));
  } else cached = fakeMaps();
  return cached;
}
export type * from './types';
