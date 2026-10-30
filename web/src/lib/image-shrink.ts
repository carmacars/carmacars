// Photos are made smaller in the browser before upload, so storage (Cloudflare R2) holds what the screens need and the
// Worker spends no CPU on it. The photo is drawn on a canvas at most `maxEdge` pixels on its long side, upright (the
// camera's rotation is applied), and saved as JPEG: that also drops the camera's metadata (location, device).
// Documents (PDFs, scans sent as files) are never passed through here: they stay exactly as sent.

export interface ShrinkPreset { maxEdge: number; quality: number }

/** Vehicle, condition, handover and listing photos: 2048 px is more than any screen or the listing pages use. */
export const PHOTO: ShrinkPreset = { maxEdge: 2048, quality: 0.8 };
/** A licence or selfie: larger and sharper, so every line on the card stays readable. */
export const ID_PHOTO: ShrinkPreset = { maxEdge: 2560, quality: 0.85 };

/** The size a photo of w by h pixels is saved at: the long side at most maxEdge, never enlarged, never 0. */
export function fitWithin(width: number, height: number, maxEdge: number): { width: number; height: number; scale: number } {
  if (!(width > 0) || !(height > 0)) return { width: 0, height: 0, scale: 1 };
  const scale = Math.min(1, maxEdge / Math.max(width, height));
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)), scale };
}

/** Whether a file is a photo the browser may redraw (not a PDF, not an SVG drawing, not a GIF animation). */
export function isShrinkable(type: string | undefined | null): boolean {
  const t = (type ?? '').toLowerCase();
  if (!t) return true; // a phone camera sometimes gives no type: try to draw it, the original is kept if that fails
  return t.startsWith('image/') && !['image/svg+xml', 'image/gif'].includes(t);
}

export interface Shrunk { blob: Blob; width: number; height: number; sourceWidth: number; sourceHeight: number; shrunk: boolean }

/** Browser only. Draws the photo at the preset's size and saves it as JPEG. When the browser cannot draw the file, it is
 *  returned as it is (width and height 0) and the server checks it as before. */
export async function shrinkImage(file: Blob, preset: ShrinkPreset = PHOTO): Promise<Shrunk> {
  const keep: Shrunk = { blob: file, width: 0, height: 0, sourceWidth: 0, sourceHeight: 0, shrunk: false };
  if (!isShrinkable(file.type) || typeof createImageBitmap !== 'function' || typeof document === 'undefined') return keep;
  let bmp: ImageBitmap | null = null;
  try {
    bmp = await createImageBitmap(file, { imageOrientation: 'from-image' });
    const size = fitWithin(bmp.width, bmp.height, preset.maxEdge);
    const c = document.createElement('canvas');
    c.width = size.width; c.height = size.height;
    const g = c.getContext('2d');
    if (!g) return keep;
    g.drawImage(bmp, 0, 0, size.width, size.height);
    const blob = await new Promise<Blob | null>((ok) => c.toBlob(ok, 'image/jpeg', preset.quality));
    if (!blob) return keep;
    // always the redrawn copy, even when it is not smaller: it carries no location or device data
    return { blob, width: size.width, height: size.height, sourceWidth: bmp.width, sourceHeight: bmp.height, shrunk: size.scale < 1 };
  } catch {
    return keep;
  } finally {
    bmp?.close();
  }
}
