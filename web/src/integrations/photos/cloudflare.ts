import type { PhotoOut, PhotoProcessor } from './types';

// Cloudflare Images transformations from inside the Worker (fetch with cf.image), on the zone the Worker
// serves (carmacars.ca). segment=foreground isolates the car (BiRefNet through Workers AI) and returns
// a transparent PNG; draw places the shadow and the cut-out on the backdrop. Billed as unique
// transformations: 5,000 a month free.
//
// When transformations are not enabled on the zone, a fetch with cf.image returns the source untouched
// (or an error page): the answer is then not the PNG or JPEG asked for. That is reported as
// reason 'not_enabled', not retryable, and the worker keeps the original and flags the photo for staff.
type Cf = { image: Record<string, unknown> };
type FetchCf = (url: string, init: RequestInit & { cf?: Cf }) => Promise<Response>;

const MIN_CUTOUT_BYTES = 8_000;   // a cut-out this small found no car in the frame

export function cloudflareImages(f: FetchCf = (u, i) => fetch(u, i as RequestInit), timeoutMs = 45_000): PhotoProcessor {
  async function transform(url: string, image: Record<string, unknown>, want: string): Promise<PhotoOut> {
    let r: Response;
    try {
      r = await f(url, { cf: { image }, signal: AbortSignal.timeout(timeoutMs) });
    } catch (e) {
      const timeout = e instanceof Error && (e.name === 'TimeoutError' || e.name === 'AbortError');
      return { ok: false, reason: timeout ? 'timeout' : 'unavailable', retryable: true, message: e instanceof Error ? e.message : 'network error' };
    }
    const type = (r.headers.get('content-type') ?? '').split(';')[0]!.trim();
    if (r.status === 429) return { ok: false, reason: 'quota', retryable: true, message: 'Image transformations are rate limited or over the month\'s allowance' };
    if (r.status >= 500) return { ok: false, reason: 'unavailable', retryable: true, message: `Image transformation failed (${r.status})` };
    if (!r.ok || type !== want) {
      const cfErr = r.headers.get('cf-resized') ?? '';
      return { ok: false, reason: 'not_enabled', retryable: false,
        message: `Image transformations did not run (status ${r.status}, ${type || 'no type'}${cfErr ? `, ${cfErr}` : ''}): enable Transformations for the zone in Cloudflare Images` };
    }
    const bytes = new Uint8Array(await r.arrayBuffer());
    return { ok: true, bytes, contentType: type, transformations: 1 };
  }
  return {
    name: 'cloudflare-images',
    async cutout(sourceUrl) {
      const out = await transform(sourceUrl, { segment: 'foreground', format: 'png', width: 2000, height: 1300, fit: 'scale-down' }, 'image/png');
      if (out.ok && out.bytes.length < MIN_CUTOUT_BYTES) return { ok: false, reason: 'no_subject', retryable: false, message: 'No car was found in the photo' };
      return out;
    },
    async composite({ backdropUrl, shadowUrl, cutoutUrl, width, height, lettering }) {
      // the sample cars' framing (studio.ts): the floor line at 74% of the height, so the car stands 26% above the
      // bottom and takes about 80% of the width; behind it the model's name, as on the samples; the shadow under it
      const carW = Math.round(width * 0.8);
      const floor = Math.round(height * 0.25);
      return transform(backdropUrl, {
        width, height, fit: 'cover', format: 'jpeg', quality: 86,
        draw: [
          ...(lettering ? [{ url: lettering.url, top: Math.round(lettering.top * height / 1200), left: 0, width: Math.round(lettering.width * width / 1800) }] : []),
          { url: shadowUrl, width: Math.round(carW * 0.96), bottom: Math.max(0, floor - Math.round(height * 0.035)) },
          { url: cutoutUrl, width: carW, height: Math.round(height * 0.6), fit: 'contain', bottom: floor }
        ]
      }, 'image/jpeg');
    },
    async normalize({ sourceUrl, width, height }) {
      return transform(sourceUrl, { width, height, fit: 'cover', gravity: 'auto', format: 'jpeg', quality: 85, brightness: 1.03, contrast: 1.03 }, 'image/jpeg');
    },
    async resize({ sourceUrl, width }) {
      return transform(sourceUrl, { width, fit: 'scale-down', format: 'webp', quality: 82 }, 'image/webp');
    }
  };
}
