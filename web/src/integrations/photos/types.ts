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
    lettering?: { url: string; top: number; width: number } | null;
    /** r28 (studio_v3): the cut-out was framed (features/listing/subject-frame.ts): cropped to the car with its contact
     *  shadow, so it is drawn at the size and place given (no separate shadow) */
    place?: { width: number; height: number; left: number; bottom: number } | null }): Promise<PhotoOut>;
  /** Orientation, crop to the aspect, size and exposure (JPEG); for interiors. */
  normalize(r: { sourceUrl: string; width: number; height: number;
    /** r28: pixels cut off each edge first (a watermark or caption at an edge) */
    trim?: { top: number; right: number; bottom: number; left: number } | null }): Promise<PhotoOut>;
  /** 0521: a base image (the studio backdrop, or the photo itself blurred) with an overlay drawn on it, both cropped to
   *  the same frame (JPEG); for the windows of interior photos (features/listing/window-check.ts). */
  layer(r: { baseUrl: string; baseBlur?: number; overlayUrl: string; width: number; height: number }): Promise<PhotoOut>;
  /** r28 B9: a small PNG of the photo, to measure it (enhance.ts). */
  preview?(r: { sourceUrl: string; width: number }): Promise<PhotoOut>;
  /** r28 B9: the light touch-up (JPEG, same size). */
  enhance?(r: { sourceUrl: string; width: number; height: number; values: { brightness: number; contrast: number; gamma: number; saturation: number; sharpen: number } }): Promise<PhotoOut>;
  /** One size variant (WebP). */
  resize(r: { sourceUrl: string; width: number }): Promise<PhotoOut>;
}
