// r48 FE (3192): a photo made small enough for the dispute pack instead of being left out (Stripe takes 4.5 MB of
// evidence in all). Decode once, scale down, encode as JPEG, smaller and smaller until it fits the share it was given.
import { decodeImage, encodeJpeg } from '../listing/showroom.ts';
import { scaleDown } from '../../integrations/photos/local.ts';

const STEPS: Array<[number, number]> = [[1200, 70], [900, 62], [700, 55], [520, 50], [380, 45], [260, 40]];

/** The bytes as they are when they fit; else a JPEG small enough (null: not an image we can read). */
export async function compressToFit(bytes: Uint8Array, target: number): Promise<{ bytes: Uint8Array; jpeg: boolean; compressed: boolean } | null> {
  const png = bytes[0] === 0x89 && bytes[1] === 0x50; const jpg = bytes[0] === 0xff && bytes[1] === 0xd8;
  if (!png && !jpg) return null;
  if (bytes.length <= target) return { bytes, jpeg: jpg, compressed: false };
  const img = await decodeImage(bytes).catch(() => null);
  if (!img) return null;
  let out: Uint8Array | null = null;
  for (const [w, q] of STEPS) {
    out = encodeJpeg(scaleDown(img, w, w), q);
    if (out.length <= target) break;
  }
  return out ? { bytes: out, jpeg: true, compressed: true } : null;
}

/** Each image's share of what is left of the budget. */
export const shareOf = (left: number, images: number, floor = 25_000): number => Math.max(floor, Math.floor(left / Math.max(images, 1)));
