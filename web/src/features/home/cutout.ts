// Release 48 O (3080): the cutouts' storage keys and limits (server/site-cutouts.ts). Pure, for the unit test.
export interface CutoutDue { vehicle_id: string; shot: 'left' | 'front_left'; name?: string; source: { kind: 'studio' | 'listing' | 'handover' | 'stock'; bucket: string; path: string; facing: 'left' | 'right' } }
/** The widest cutout kept (the hero's car is drawn at most about 1000 CSS pixels wide on a 2x screen at 1440). */
export const CUTOUT_MAX_WIDTH = 1600;
/** vehicle-public/site/cutouts/<car>/<shot>-<hash>.webp: a new cutout gets a new name (no stale copy at the edge). */
export function cutoutKey(vehicle: string, shot: string, sha1: string): string {
  if (!/^[0-9a-f-]{36}$/i.test(vehicle)) throw new Error('not a car id');
  if (!/^[a-z_]{2,20}$/.test(shot)) throw new Error('not a shot');
  return `site/cutouts/${vehicle.toLowerCase()}/${shot}-${sha1.slice(0, 12)}.webp`;
}

/** The box of the largest connected shape of an alpha mask (alpha above `min`), in mask pixels: the car, without a sign or
 *  lettering on the wall behind it that the background remover kept apart from it. null: nothing in the mask. */
export function largestBlobBox(alpha: Uint8Array, w: number, h: number, min = 128): { left: number; top: number; width: number; height: number } | null {
  const seen = new Uint8Array(w * h);
  let best: { n: number; x0: number; y0: number; x1: number; y1: number } | null = null;
  const stack: number[] = [];
  for (let i = 0; i < w * h; i++) {
    if (seen[i] || alpha[i]! <= min) continue;
    let n = 0, x0 = w, y0 = h, x1 = -1, y1 = -1;
    stack.push(i); seen[i] = 1;
    while (stack.length) {
      const p = stack.pop()!; const x = p % w, y = (p - x) / w; n++;
      if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
      for (const q of [x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1]) {
        if (q >= 0 && !seen[q] && alpha[q]! > min) { seen[q] = 1; stack.push(q); }
      }
    }
    if (!best || n > best.n) best = { n, x0, y0, x1, y1 };
  }
  return best ? { left: best.x0, top: best.y0, width: best.x1 - best.x0 + 1, height: best.y1 - best.y0 + 1 } : null;
}
