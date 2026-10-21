// The photo module (docs/blueprint/09-listing-pipeline.md section 5.4): cut the car out, place it on the
// CarmaCars studio backdrop with a soft ground shadow, normalize interiors, and make the size variants the
// site uses. Adapters: cloudflare (Cloudflare Images transformations from the Worker: segment=foreground,
// draw), fake (local work and tests). Storage stays with the worker; the adapter only transforms.
export type PhotoFailureReason = 'not_enabled' | 'no_subject' | 'quota' | 'timeout' | 'unavailable';

export type PhotoOut =
  | { ok: true; bytes: Uint8Array; contentType: string; transformations: number }
  | { ok: false; reason: PhotoFailureReason; retryable: boolean; message: string };

export interface PhotoProcessor {
  readonly name: 'cloudflare-images' | 'fake';
  /** The subject on a transparent background (PNG). */
  cutout(sourceUrl: string): Promise<PhotoOut>;
  /** The backdrop with the model-name lettering (a transparent band placed at lettering.top), the shadow and the
   *  cut-out drawn on it, the car standing on the floor line (JPEG). */
  composite(r: { backdropUrl: string; shadowUrl: string; cutoutUrl: string; width: number; height: number;
    lettering?: { url: string; top: number; width: number } | null }): Promise<PhotoOut>;
  /** Orientation, crop to the aspect, size and exposure (JPEG); for interiors. */
  normalize(r: { sourceUrl: string; width: number; height: number }): Promise<PhotoOut>;
  /** One size variant (WebP). */
  resize(r: { sourceUrl: string; width: number }): Promise<PhotoOut>;
}
