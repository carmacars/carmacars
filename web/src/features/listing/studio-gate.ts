// R50 hotfix 2 (migration 5080): the studio gate of standard r48.4. Why the gate changed: under r48.3 (3701) Gemini was asked
// to paint the car INTO the dealership background plate, and the gate then measured the wall, the floor and a contact
// shadow against that plate (mean colour within 0.085 and 0.11). An image model redraws the whole frame, so the room never
// came back within those limits, and the gate compared the render cropped onto its target with the plate NOT cropped
// (worker.ts before 5080: cropResize on the render, fitFrame on the plate), so the regions it compared were not the same
// part of the room. Every render was paid for and then refused for a reason it could not fix.
// r48.4: Gemini makes only the car, alone on a flat key colour (green, or magenta for a green car). The site keys it out
// (chromaKey) and puts it on the drawn dealership background with the CarmaCars sign and the car's name (studio-composite.ts),
// at the same size and place for every car of that view (STUDIO_FRAME). The background, the placement and the shadow are
// then the site's own, the same every time, and the gate checks only what the words ask Gemini for: a flat key background
// with the whole car inside the frame. It runs on the site's CPU, before the paid check. The view and the direction are the
// check's (r48.ts judgeR48), with one rule (r48.ts viewReasons). Pure: no I/O, unit tested in studio-gate.test.ts.
import type { Rgba } from './subject-frame.ts';

/** A box in fractions of the frame (0 to 1). */
export interface FBox { x: number; y: number; w: number; h: number }
/** Where the car stands in each outside view: its width as a share of the frame, its horizontal centre, and the line where
 *  its tyres meet the floor (a share of the height). The same numbers for every car (studio-composite.ts places it). */
export interface FrameTarget { width: number; cx: number; bottom: number }
export const STUDIO_FRAME: Readonly<Record<string, FrameTarget>> = {
  front_left: { width: 0.80, cx: 0.5, bottom: 0.84 },
  left: { width: 0.84, cx: 0.5, bottom: 0.82 },
  rear_left: { width: 0.78, cx: 0.5, bottom: 0.84 },
  front: { width: 0.60, cx: 0.5, bottom: 0.84 },
  rear: { width: 0.60, cx: 0.5, bottom: 0.84 }
};
/** A real photo added after the standard views (5080, shot 'studio_extra'): its own angle, placed like the showroom's cars. */
export const EXTRA_FRAME: FrameTarget = { width: 0.74, cx: 0.5, bottom: 0.82 };
/** The car is at most this share of the frame high (a tall SUV seen from the front is held by its height, under the sign). */
export const STUDIO_MAX_HEIGHT = 0.56;

/** The window of an image scaled to width x height (bilinear). The drive-off matte crops the plate with it (site-cutouts.ts). */
export function cropResize(img: Rgba, win: FBox, width: number, height: number): Rgba {
  const d = new Uint8ClampedArray(width * height * 4);
  const sx = (win.w * img.width) / width, sy = (win.h * img.height) / height;
  const ox = win.x * img.width, oy = win.y * img.height;
  const W = img.width, H = img.height, s = img.data;
  for (let y = 0; y < height; y++) {
    const fy = Math.max(0, Math.min(H - 1, oy + (y + 0.5) * sy - 0.5));
    const y0 = Math.floor(fy), y1 = Math.min(H - 1, y0 + 1), ty = fy - y0;
    for (let x = 0; x < width; x++) {
      const fx = Math.max(0, Math.min(W - 1, ox + (x + 0.5) * sx - 0.5));
      const x0 = Math.floor(fx), x1 = Math.min(W - 1, x0 + 1), tx = fx - x0;
      const a = (y0 * W + x0) * 4, b = (y0 * W + x1) * 4, c = (y1 * W + x0) * 4, e = (y1 * W + x1) * 4, o = (y * width + x) * 4;
      for (let ch = 0; ch < 3; ch++) {
        d[o + ch] = (s[a + ch]! * (1 - tx) + s[b + ch]! * tx) * (1 - ty) + (s[c + ch]! * (1 - tx) + s[e + ch]! * tx) * ty;
      }
      d[o + 3] = 255;
    }
  }
  return { width, height, data: d };
}

// ================================================================ the key colour
export type KeyName = 'green' | 'magenta';
/** The words and the colour asked for. Magenta for a green car (a green key would eat its paint). */
export const KEY: Readonly<Record<KeyName, { words: string; hex: string }>> = {
  green: { words: 'pure chroma-key green', hex: '#00FF00' },
  magenta: { words: 'pure chroma-key magenta', hex: '#FF00FF' }
};
export const keyFor = (colour: string | null | undefined): KeyName =>
  (/green|olive|lime|teal|emerald|jade|mint|sage|khaki|army/i.test(colour ?? '') ? 'magenta' : 'green');
/** How much a pixel is the key colour (0 to 1): the key's channel(s) above the others by more than KEY_SOFT, fully key at
 *  KEY_SOFT + KEY_RAMP. Grey, white, black and every paint colour but the key's own stay 0. */
export const KEY_SOFT = 30;
export const KEY_RAMP = 80;
export function keyness(r: number, g: number, b: number, key: KeyName): number {
  const lead = key === 'green' ? g - Math.max(r, b) : Math.min(r, b) - g;
  return lead <= KEY_SOFT ? 0 : Math.min(1, (lead - KEY_SOFT) / KEY_RAMP);
}
/** The frame's border must be this much key (Gemini drew a room, a floor or a gradient otherwise). */
export const KEY_BORDER_MIN = 0.9;
/** At most this share of the border may be car (the car cut off by the frame otherwise). */
export const KEY_EDGE_MAX = 0.01;
/** The car at least this share of the frame wide (else Gemini drew it far away or not at all). */
export const KEY_CAR_MIN = 0.25;

export interface Keyed {
  /** the frame with the key made transparent and its spill taken off the car's edge */
  cut: Rgba;
  /** share of the border samples that are key; share that are car */
  border: number; edge: number;
  /** the car's box (alpha at least half), null when there is none */
  box: FBox | null;
}

/** Keys out the flat background of a generated view. Pure. */
export function chromaKey(img: Rgba, key: KeyName): Keyed {
  const W = img.width, H = img.height, s = img.data;
  const d = new Uint8ClampedArray(s.length);
  let x0 = W, y0 = H, x1 = -1, y1 = -1;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    let r = s[i]!, g = s[i + 1]!, b = s[i + 2]!;
    const k = keyness(r, g, b, key);
    // the key's spill on the car's edge and in its glass: the key's channel brought down to the others
    if (key === 'green' && g > Math.max(r, b)) g = Math.max(r, b);
    if (key === 'magenta' && Math.min(r, b) > g) { const m = Math.min(r, b) - g; r -= m; b -= m; }
    const a = Math.round((1 - k) * 255);
    d[i] = r; d[i + 1] = g; d[i + 2] = b; d[i + 3] = a;
    if (a >= 128) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
  }
  // the border: a band of 1.5 percent of the frame on every side, sampled
  let n = 0, keyed = 0, car = 0;
  const band = Math.max(1, Math.round(Math.min(W, H) * 0.015));
  const sample = (x: number, y: number) => { const a = d[(y * W + x) * 4 + 3]!; n++; if (a < 64) keyed++; else if (a >= 192) car++; };
  for (let x = 0; x < W; x += 2) for (let t = 0; t < band; t += 2) { sample(x, t); sample(x, H - 1 - t); }
  for (let y = band; y < H - band; y += 2) for (let t = 0; t < band; t += 2) { sample(t, y); sample(W - 1 - t, y); }
  return { cut: { width: W, height: H, data: d }, border: n ? keyed / n : 0, edge: n ? car / n : 0,
    box: x1 >= x0 ? { x: x0 / W, y: y0 / H, w: (x1 - x0 + 1) / W, h: (y1 - y0 + 1) / H } : null };
}

// ================================================================ the gate
export type GateReason = 'gate_key_background' | 'gate_key_cropped' | 'gate_key_no_car';
export const GATE_FEEDBACK: Readonly<Record<GateReason, string>> = {
  gate_key_background: 'the background was not one flat key colour from edge to edge (no floor, room, gradient or shadow)',
  gate_key_cropped: 'the car touched or ran past the edge of the frame (leave a clear margin on every side)',
  gate_key_no_car: 'the car was missing or far too small in the frame'
};
export interface GateMeasures { border?: number; edge?: number; car?: FBox; win?: FBox }
export interface GateVerdict { pass: boolean; reasons: GateReason[]; measures: GateMeasures }

/** The gate of an outside view or an extra photo: the key is flat and the whole car stands inside the frame. Inside views
 *  are never keyed (nothing is swapped there): they pass here and are judged by the check alone. */
export function gateKey(k: Keyed | null): GateVerdict {
  if (!k) return { pass: true, reasons: [], measures: {} };
  const reasons: GateReason[] = [];
  const m: GateMeasures = { border: +k.border.toFixed(3), edge: +k.edge.toFixed(3), ...(k.box ? { car: { x: +k.box.x.toFixed(3), y: +k.box.y.toFixed(3), w: +k.box.w.toFixed(3), h: +k.box.h.toFixed(3) } } : {}) };
  if (!k.box || k.box.w < KEY_CAR_MIN) reasons.push('gate_key_no_car');
  // a room or a floor covers the whole border; half-key samples are a gradient or a drawn shadow; a car cut off covers a part
  if (k.edge > 0.5 || k.border + k.edge < KEY_BORDER_MIN) reasons.push('gate_key_background');
  else if (k.edge > KEY_EDGE_MAX) reasons.push('gate_key_cropped');
  return { pass: !reasons.length, reasons, measures: m };
}
