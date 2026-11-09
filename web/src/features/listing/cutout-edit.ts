// The cut-out editor's pixel work (release 33, 0700), pure so the unit tests run it: the mask is the segmenter's alpha
// (one byte a pixel, at the cut-out's size); the brush erases what is left of the background or restores what the
// segmenter took off (a mirror, the roof, a wheel) from the original photo; the car sent back to the worker is the
// original's colours with the edited alpha (the worker frames it as any cut-out: subject-frame.ts).
import { frameRgba, placeSubject, adjustPlace, type Adjust, type Rgba } from './subject-frame.ts';

export type Brush = 'erase' | 'restore';
export interface Rect { x: number; y: number; w: number; h: number }

/** The alpha of a cut-out PNG's pixels (RGBA) as a mask. */
export function alphaOf(img: { width: number; height: number; data: Uint8ClampedArray }): Uint8ClampedArray {
  const m = new Uint8ClampedArray(img.width * img.height);
  for (let i = 0; i < m.length; i++) m[i] = img.data[i * 4 + 3]!;
  return m;
}

/** One dab of the brush at (cx, cy), radius r (mask pixels): full strength inside 60% of r, soft to the edge. Erase
 *  lowers the alpha, restore raises it; never past what the dab gives. Returns the rectangle it touched (or null). */
export function dab(mask: Uint8ClampedArray, W: number, H: number, cx: number, cy: number, r: number, mode: Brush): Rect | null {
  r = Math.max(1, r);
  const x0 = Math.max(0, Math.floor(cx - r)), x1 = Math.min(W - 1, Math.ceil(cx + r));
  const y0 = Math.max(0, Math.floor(cy - r)), y1 = Math.min(H - 1, Math.ceil(cy + r));
  if (x1 < x0 || y1 < y0) return null;
  const core = r * 0.6;
  for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
    const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
    if (d > r) continue;
    const f = d <= core ? 1 : 1 - (d - core) / (r - core);
    const i = y * W + x, a = mask[i]!;
    mask[i] = mode === 'erase' ? Math.min(a, Math.round(255 * (1 - f))) : Math.max(a, Math.round(255 * f));
  }
  return { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1 };
}

/** A stroke from (ax, ay) to (bx, by): dabs a third of the radius apart. Returns the rectangle touched. */
export function stroke(mask: Uint8ClampedArray, W: number, H: number, ax: number, ay: number, bx: number, by: number, r: number, mode: Brush): Rect | null {
  const n = Math.max(1, Math.ceil(Math.hypot(bx - ax, by - ay) / Math.max(1, r / 3)));
  let box: Rect | null = null;
  for (let k = 0; k <= n; k++) box = union(box, dab(mask, W, H, ax + ((bx - ax) * k) / n, ay + ((by - ay) * k) / n, r, mode));
  return box;
}

export function union(a: Rect | null, b: Rect | null): Rect | null {
  if (!a) return b; if (!b) return a;
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}

/** The car as the worker gets it: the original's colours (already at the mask's size) with the mask as alpha. With a
 *  rectangle, only that part of `out` is written (the editor redraws what the brush touched). */
export function compose(orig: Uint8ClampedArray, mask: Uint8ClampedArray, W: number, H: number, out?: Uint8ClampedArray, rect?: Rect | null): Uint8ClampedArray {
  const o = out ?? new Uint8ClampedArray(W * H * 4);
  const r = rect ?? { x: 0, y: 0, w: W, h: H };
  for (let y = r.y; y < r.y + r.h; y++) for (let x = r.x; x < r.x + r.w; x++) {
    const i = y * W + x, p = i * 4;
    o[p] = orig[p]!; o[p + 1] = orig[p + 1]!; o[p + 2] = orig[p + 2]!; o[p + 3] = mask[i]!;
  }
  return o;
}

/** Whether two masks differ (the editor's Save is off until something changed, with the move and size). */
export function masksDiffer(a: Uint8ClampedArray, b: Uint8ClampedArray): boolean {
  if (a.length !== b.length) return true;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return true;
  return false;
}

export const NO_ADJUST: Adjust = { dx: 0, dy: 0, scale: 1 };
export const sameAdjust = (a: Adjust | null | undefined, b: Adjust | null | undefined) => {
  const x = a ?? NO_ADJUST, y = b ?? NO_ADJUST;
  return Math.abs(x.dx - y.dx) < 1e-4 && Math.abs(x.dy - y.dy) < 1e-4 && Math.abs(x.scale - y.scale) < 1e-4;
};

/** The studio preview: the car framed as the worker frames it, and where it goes on the frame of W x H with the
 *  editor's move and size. null when the mask holds no car. */
export function studioPlan(car: Rgba, adjust: Adjust | null, W = 1800, H = 1200, fit?: { carWidth: number; carHeight: number; floor: number }) {
  const f = frameRgba(car);
  if (!f) return null;
  // r35: a showroom photo's car stands where the showroom puts it (SHOWROOM_FIT)
  const base = placeSubject(f, W, H, fit);
  return { framed: f.image, base, place: adjustPlace(base, adjust, W, H) };
}
