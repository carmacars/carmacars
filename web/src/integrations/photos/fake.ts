import type { PhotoOut, PhotoProcessor } from './types';

// For local work and tests: returns the source bytes as they are (a fetch of the local storage link),
// so the pipeline runs end to end without Cloudflare. PHOTO_FAKE_MODE=not_enabled behaves like a zone
// without transformations (the worker's fallback path).
export function fakePhotos(get: (url: string) => Promise<Uint8Array | null>, mode: 'ok' | 'not_enabled' = 'ok'): PhotoProcessor {
  const pass = async (url: string, contentType: string): Promise<PhotoOut> => {
    if (mode === 'not_enabled') return { ok: false, reason: 'not_enabled', retryable: false, message: 'Image transformations are not enabled (fake)' };
    const bytes = await get(url);
    if (!bytes) return { ok: false, reason: 'unavailable', retryable: true, message: 'The source could not be read' };
    return { ok: true, bytes, contentType, transformations: 0 };
  };
  return {
    name: 'fake',
    cutout: (u) => pass(u, 'image/png'),
    composite: (r) => pass(r.cutoutUrl, 'image/jpeg'),
    normalize: (r) => pass(r.sourceUrl, 'image/jpeg'),
    resize: (r) => pass(r.sourceUrl, 'image/webp')
  };
}
