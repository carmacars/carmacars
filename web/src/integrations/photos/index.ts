import 'server-only';
import { env } from '@/lib/env';
import type { PhotoProcessor } from './types';
import { fakePhotos } from './fake';

// PHOTO_PROVIDER=cloudflare: Cloudflare Images transformations from the Worker (production);
// fake: the photos pass through unchanged (local work, tests). PHOTO_FAKE_MODE=not_enabled makes the
// fake behave like a zone without transformations, to exercise the fallback.
// r35 (owner, Nov 8): in production the steps are made locally (local.ts) and Cloudflare is asked only for the cut-out and
// a HEIC photo, unless Program settings' listing_cf_transformations (off) is on; any refusal of Cloudflare's falls back to local.
export async function photoProcessor(read: (url: string) => Promise<Uint8Array | null>, o: { cfAll?: boolean } = {}): Promise<PhotoProcessor> {
  const e = env();
  if (e.PHOTO_PROVIDER === 'cloudflare') {
    const [{ cloudflareImages }, { localImages, hybridPhotos }] = await Promise.all([import('./cloudflare'), import('./local')]);
    const load = async (url: string) => (await read(url).catch(() => null))
      ?? await fetch(url, { signal: AbortSignal.timeout(20_000) }).then(async (r) => (r.ok ? new Uint8Array(await r.arrayBuffer()) : null)).catch(() => null);
    // r42: on the company's server the transformations are asked for by address on the zone (Cloudflare's free proxy)
    const { hostingTarget } = await import('@/lib/platform/runtime');
    const { urlFormatFetch } = await import('./cloudflare');
    const cf = hostingTarget() === 'node' ? cloudflareImages(urlFormatFetch(e.NEXT_PUBLIC_APP_URL)) : cloudflareImages();
    return hybridPhotos(localImages(load), cf, !!o.cfAll);
  }
  return fakePhotos(read, e.PHOTO_FAKE_MODE);
}
export type * from './types';
