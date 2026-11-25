// Release 50 (5030, docs/changes/2026-11-25-r50-car-cards.md): the drive-off matte of a studio side render. The cards' car
// drives off its studio floor; since R50 every cover is a studio render (3701), so the car is cut from the render itself:
// the render is compared with the scene's background plate, cropped by the same window the studio gate used (r45.gate.measures.win),
// inside the car's box from the check (r45.gate.measures.car), and above the line where the tyres meet the floor (the
// contact shadow and the floor's reflection stay on the floor). No background remover (rembg) and no sharp: it runs in the
// Cloudflare Worker and on the company server alike (server/site-cutouts.ts). The result is a small alpha mask in the
// render's own frame (the card masks the render it already shows) and the plate cropped the same way (what is behind the
// car once it has gone). Pure: unit tested in studio-matte.test.ts.
import type { Rgba } from './subject-frame.ts';
import type { FBox } from './studio-gate.ts';

/** The matte's size: the render's 3:2 frame at card size (CSS scales it; its edge is feathered). */
export const MATTE_W = 480;
export const MATTE_H = 320;
/** A pixel differs from the plate when one channel is this far from it (0 to 1). */
export const MATTE_DIFF = 0.075;
/** Share of the matte that must be car for it to be kept (an empty or broken matte is never shown). */
export const MATTE_MIN_FILL = 0.35;

/** An image scaled to w x h by averaging (a soft scale: noise and a pixel of drift between the render and the plate vanish). */
export function boxScale(img: Rgba, w: number, h: number): Float32Array {
  const out = new Float32Array(w * h * 3);
  const sx = img.width / w, sy = img.height / h, W = img.width, s = img.data;
  for (let y = 0; y < h; y++) {
    const y0 = Math.floor(y * sy), y1 = Math.max(y0 + 1, Math.floor((y + 1) * sy));
    for (let x = 0; x < w; x++) {
      const x0 = Math.floor(x * sx), x1 = Math.max(x0 + 1, Math.floor((x + 1) * sx));
      let r = 0, g = 0, b = 0, n = 0;
      for (let yy = y0; yy < y1; yy++) for (let xx = x0; xx < x1; xx++) { const o = (yy * W + xx) * 4; r += s[o]!; g += s[o + 1]!; b += s[o + 2]!; n++; }
      const o = (y * w + x) * 3; out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n;
    }
  }
  return out;
}

export interface Matte { width: number; height: number; alpha: Uint8Array; fill: number }

/** The car's alpha (0 to 255) in the render's frame. `car`: its box in fractions of the frame (the gate's measure). */
export function studioMatte(img: Rgba, plate: Rgba, car: FBox, w = MATTE_W, h = MATTE_H): Matte {
  const a = boxScale(img, w, h), p = boxScale(plate, w, h);
  // where to look: the car's box, a little wider and taller (the check's box is a few pixels loose either way), never below
  // the floor line (+1% for the tyres' round)
  const X0 = Math.max(0, Math.floor((car.x - 0.02) * w)), X1 = Math.min(w - 1, Math.ceil((car.x + car.w + 0.02) * w));
  const Y0 = Math.max(0, Math.floor((car.y - 0.03) * h)), Y1 = Math.min(h - 1, Math.ceil((car.y + car.h + 0.01) * h));
  const fg = new Uint8Array(w * h);
  for (let y = Y0; y <= Y1; y++) for (let x = X0; x <= X1; x++) {
    const o = (y * w + x) * 3;
    const d = Math.max(Math.abs(a[o]! - p[o]!), Math.abs(a[o + 1]! - p[o + 1]!), Math.abs(a[o + 2]! - p[o + 2]!)) / 255;
    if (d > MATTE_DIFF) fg[y * w + x] = 1;
  }
  // a car seen from the side is solid along every row and every column (its windows and wheel arches show the wall or the
  // floor behind but belong to it): fill between the outermost car pixels of each row, and of each column
  const rows = new Uint8Array(w * h), cols = new Uint8Array(w * h);
  for (let y = Y0; y <= Y1; y++) {
    let l = -1, r = -1;
    for (let x = X0; x <= X1; x++) if (fg[y * w + x]) { if (l < 0) l = x; r = x; }
    if (l >= 0 && r - l >= 2) for (let x = l; x <= r; x++) rows[y * w + x] = 1;
  }
  for (let x = X0; x <= X1; x++) {
    let t = -1, b = -1;
    for (let y = Y0; y <= Y1; y++) if (fg[y * w + x]) { if (t < 0) t = y; b = y; }
    if (t >= 0 && b - t >= 2) for (let y = t; y <= b; y++) cols[y * w + x] = 1;
  }
  // grown by 2 matte pixels, then a feathered edge (a 3 x 3 average twice): the car's own edge stays whole in the moving
  // layer and leaves no outline on the floor layer (which shows the render outside the matte)
  let n = 0;
  const core = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) if (rows[i] && cols[i]) { core[i] = 1; n++; }
  let m = new Float32Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let on = 0;
    for (let dy = -2; dy <= 2 && !on; dy++) for (let dx = -2; dx <= 2; dx++) {
      const yy = y + dy, xx = x + dx;
      if (yy >= 0 && yy < h && xx >= 0 && xx < w && core[yy * w + xx]) { on = 1; break; }
    }
    m[y * w + x] = on;
  }
  for (let pass = 0; pass < 2; pass++) {
    const o = new Float32Array(w * h);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      let s = 0, c = 0;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const yy = y + dy, xx = x + dx; if (yy < 0 || yy >= h || xx < 0 || xx >= w) continue;
        s += m[yy * w + xx]!; c++;
      }
      o[y * w + x] = s / c;
    }
    m = o;
  }
  const alpha = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) alpha[i] = Math.round(Math.min(1, m[i]!) * 255);
  const boxArea = Math.max(1, (X1 - X0 + 1) * (Y1 - Y0 + 1));
  return { width: w, height: h, alpha, fill: n / boxArea };
}

/** A matte worth showing: enough of the box is car, and the car reaches near both ends of its box (not a fragment). */
export function matteUsable(mt: Matte, car: FBox): boolean {
  if (mt.fill < MATTE_MIN_FILL) return false;
  const { width: w, height: h, alpha } = mt;
  let l = w, r = -1;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (alpha[y * w + x]! > 128) { if (x < l) l = x; if (x > r) r = x; }
  if (r < 0) return false;
  return (r - l) / w >= car.w * 0.8;
}

/** The matte as an image whose alpha is the car (black, so it compresses to a few kilobytes as a PNG). */
export function matteRgba(mt: Matte): Rgba {
  const d = new Uint8ClampedArray(mt.width * mt.height * 4);
  for (let i = 0; i < mt.alpha.length; i++) d[i * 4 + 3] = mt.alpha[i]!;
  return { width: mt.width, height: mt.height, data: d };
}

/** The gate's crop window and car box from a render's r45 (r45.gate.measures.win and .car); null when missing. */
export function gateFrame(r45: unknown): { win: FBox; car: FBox } | null {
  const g = (r45 as { gate?: { measures?: { car?: unknown; win?: unknown } } } | null)?.gate;
  const ok = (b: unknown): b is FBox => !!b && typeof b === 'object' && ['x', 'y', 'w', 'h'].every((k) => typeof (b as Record<string, unknown>)[k] === 'number' && Number.isFinite((b as Record<string, number>)[k]));
  const win = g?.measures?.win, car = g?.measures?.car;
  if (!ok(win) || !ok(car) || win.w <= 0 || win.h <= 0 || car.w <= 0.1 || car.h <= 0.05) return null;
  return { win, car };
}
