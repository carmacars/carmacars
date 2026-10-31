// The photo formats a licence or document upload takes (Release 24b, owner: the handover essentials): JPG, PNG, HEIC
// and HEIF (iPhone), WEBP, GIF and PDF (a scan: its first page), straight from the camera or from the files. Every one
// is turned into a standard JPEG in the browser before it is sent (location data dropped, large photos made smaller).
export const PHOTO_ACCEPT = 'image/*,.jpg,.jpeg,.png,.heic,.heif,.webp,application/pdf,.pdf';
export const MAX_SOURCE_BYTES = 40 * 1024 * 1024;
export const LONG_SIDE = 2000;
export const TARGET_BYTES = 3 * 1024 * 1024;

export type SourceKind = 'jpeg' | 'png' | 'webp' | 'heic' | 'gif' | 'pdf' | 'other';

/** What a picked file is, by its type or (when the phone gives none, as HEIC often does) its name. */
export function sourceKind(f: { type?: string | null; name?: string | null }): SourceKind {
  const t = (f.type ?? '').toLowerCase();
  const n = (f.name ?? '').toLowerCase();
  if (t === 'application/pdf' || n.endsWith('.pdf')) return 'pdf';
  if (t === 'image/heic' || t === 'image/heif' || t === 'image/heic-sequence' || t === 'image/heif-sequence' || /\.(heic|heif)$/.test(n)) return 'heic';
  if (t === 'image/jpeg' || t === 'image/jpg' || t === 'image/pjpeg' || /\.(jpe?g)$/.test(n)) return 'jpeg';
  if (t === 'image/png' || n.endsWith('.png')) return 'png';
  if (t === 'image/webp' || n.endsWith('.webp')) return 'webp';
  if (t === 'image/gif' || n.endsWith('.gif')) return 'gif';
  if (t.startsWith('image/')) return 'jpeg';
  return 'other';
}

/** The plain-language refusal of a file, before anything is read; null when it is fine. */
export function sourceProblem(f: { type?: string | null; name?: string | null; size?: number | null }): string | null {
  if (!f.size) return 'That file is empty. Take the photo again.';
  if (f.size > MAX_SOURCE_BYTES) return 'That file is larger than 40 MB. Take a new photo, or send a smaller scan.';
  if (sourceKind(f) === 'other') return 'Upload a photo (JPG, PNG, HEIC, WEBP) or a PDF scan.';
  return null;
}

export const HEIC_UNREADABLE = 'This phone could not open that HEIC photo. Use Take photo instead, or on iPhone set Settings, Camera, Formats to Most Compatible and try again.';
export const UNREADABLE = 'We could not read that file. Take a new photo of the licence, flat and in good light.';

/** The scale for the long side, and the JPEG qualities tried in turn until the photo is small enough. */
export function fitScale(w: number, h: number, longSide = LONG_SIDE): number {
  return Math.min(1, longSide / Math.max(w, h, 1));
}
export const QUALITIES = [0.88, 0.8, 0.7, 0.6];
