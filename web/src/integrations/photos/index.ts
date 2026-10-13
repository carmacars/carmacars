import 'server-only';
import { env } from '@/lib/env';
import type { PhotoProcessor } from './types';
import { fakePhotos } from './fake';

// PHOTO_PROVIDER=cloudflare: Cloudflare Images transformations from the Worker (production);
// fake: the photos pass through unchanged (local work, tests). PHOTO_FAKE_MODE=not_enabled makes the
// fake behave like a zone without transformations, to exercise the fallback.
export async function photoProcessor(read: (url: string) => Promise<Uint8Array | null>): Promise<PhotoProcessor> {
  const e = env();
  if (e.PHOTO_PROVIDER === 'cloudflare') {
    const { cloudflareImages } = await import('./cloudflare');
    return cloudflareImages();
  }
  return fakePhotos(read, e.PHOTO_FAKE_MODE);
}
export type * from './types';
