// Release 50 (migration 3701): the studio consistency gate. The owner (Nov 24): "Some of the backgrounds for the photos aren't
// consistent... makes us look like AI slop. And you still aren't doing the consistent angles using AI." Every public photo of
// a car is a studio render that passed this gate; nothing else is shown (app.public_listing_photos).
//   * Framing is not left to the image model. It is asked for the car a little smaller than the target (FRAME_ASK), the
//     check model reads the car's box, and normalizeFrame crops and scales the render so that the car lands exactly on the
//     target of its view (STUDIO_FRAME: its width in the frame, its horizontal centre, the line where the tyres meet the
//     floor). Every car's front three-quarter is then the same size in the same place, and so on for each view.
//   * The gate then measures, on the normalized render: the car's box against the target (scale and position), the wall
//     and the floor against the one reference plate of the scene (the same plate for every outside view), the contact
//     shadow under the car, and the view and the way the nose points (from the check).
//   * A refusal names its reasons (GATE_FEEDBACK), the next try is told them; after three tries the view is flagged for an
//     Admin with the reasons (2840's rule).
// Pure: no I/O, unit tested in studio-gate.test.ts.
import type { Rgba } from './subject-frame.ts';

/** A box in fractions of the frame (0 to 1). */
export interface FBox { x: number; y: number; w: number; h: number }
/** Where the car must stand in each outside view: its width as a share of the frame, its horizontal centre, and the line
 *  where its tyres meet the floor (a share of the height). The same numbers for every car. */
export interface FrameTarget { width: number; cx: number; bottom: number }
export const STUDIO_FRAME: Readonly<Record<string, FrameTarget>> = {
  front_left: { width: 0.80, cx: 0.5, bottom: 0.84 },
  left: { width: 0.84, cx: 0.5, bottom: 0.82 },
  rear_left: { width: 0.78, cx: 0.5, bottom: 0.84 },
  front: { width: 0.60, cx: 0.5, bottom: 0.84 },
  rear: { width: 0.60, cx: 0.5, bottom: 0.84 }
};
/** The image model is asked for the car this much smaller than the target, so the crop only ever zooms in a little. */
export const FRAME_ASK = 0.92;
/** How far the normalized car may be from its target (shares of the frame). */
export const FRAME_TOL = { width: 0.035, cx: 0.03, bottom: 0.03 } as const;
/** The most a render is enlarged to put the car on its target (more would soften it). */
export const MAX_ZOOM = 1.3;
/** How far the wall and the floor may be from the reference plate (mean colour distance, 0 to 1). */
export const WALL_MAX = 0.085;
export const FLOOR_MAX = 0.11;
/** The contact shadow: the floor just under the car is at least this much darker than the plate's floor there (0 to 1). */
export const SHADOW_MIN = 0.03;

export type GateReason = 'gate_no_car_box' | 'gate_car_too_big' | 'gate_car_off_target' | 'gate_wall_mismatch' | 'gate_floor_mismatch'
  | 'gate_no_shadow' | 'gate_no_plate' | 'gate_wrong_view' | 'gate_wrong_direction';
export const GATE_FEEDBACK: Readonly<Record<GateReason, string>> = {
  gate_no_car_box: 'the whole car could not be found in the frame',
  gate_car_too_big: 'the car filled too much of the frame (leave more floor and room around it)',
  gate_car_off_target: 'the car was not centred at the asked size and height in the frame',
  gate_wall_mismatch: 'the back wall and lights were not exactly the background plate',
  gate_floor_mismatch: 'the floor was not exactly the background plate\'s floor',
  gate_no_shadow: 'there was no dark contact shadow under the car',
  gate_no_plate: 'the background plate was missing',
  gate_wrong_view: 'it was not exactly the asked view',
  gate_wrong_direction: 'the car faced the wrong way'
};
export const FACE: Readonly<Record<string, 'left' | 'right'>> = { front_left: 'left', left: 'left', rear_left: 'right' };

/** The car's box from the check's answer ("car_box": [ymin, xmin, ymax, xmax] on a 0 to 1000 grid); null when unusable. */
export function readCarBox(answer: unknown): FBox | null {
  const b = (answer as { car_box?: unknown } | null)?.car_box;
  if (!Array.isArray(b) || b.length !== 4 || !b.every((n) => typeof n === 'number' && Number.isFinite(n))) return null;
  const [y0, x0, y1, x1] = (b as number[]).map((n) => Math.max(0, Math.min(1000, n)) / 1000) as [number, number, number, number];
  if (x1 - x0 < 0.15 || y1 - y0 < 0.1) return null;
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

/** The crop that puts the car on its target: the window (fractions of the render) and the car's box inside it. A car that is
 *  already bigger than its target cannot be made smaller by a crop (gate_car_too_big); a zoom above MAX_ZOOM is refused too. */
export function frameWindow(car: FBox, t: FrameTarget): { win: FBox; car: FBox } | { error: GateReason } {
  const s = t.width / car.w;
  if (s < 1 - FRAME_TOL.width / t.width) return { error: 'gate_car_too_big' };
  const k = Math.max(1, Math.min(s, MAX_ZOOM));
  const w = 1 / k, h = 1 / k;
  const bottom = car.y + car.h, cx = car.x + car.w / 2;
  const x0 = Math.max(0, Math.min(1 - w, cx - t.cx * w));
  const y0 = Math.max(0, Math.min(1 - h, bottom - t.bottom * h));
  return { win: { x: x0, y: y0, w, h }, car: { x: (car.x - x0) / w, y: (car.y - y0) / h, w: car.w / w, h: car.h / h } };
}

/** The window of an image scaled to width x height (bilinear). */
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

/** The mean colour (0 to 255 each) of a region given in fractions, leaving out a box (the car); null when nothing is left. */
export function regionMean(img: Rgba, r: FBox, skip?: FBox | null): [number, number, number] | null {
  const GX = 60, GY = 30;
  let n = 0; const m: [number, number, number] = [0, 0, 0];
  for (let gy = 0; gy < GY; gy++) for (let gx = 0; gx < GX; gx++) {
    const fx = r.x + ((gx + 0.5) / GX) * r.w, fy = r.y + ((gy + 0.5) / GY) * r.h;
    if (skip && fx >= skip.x && fx <= skip.x + skip.w && fy >= skip.y && fy <= skip.y + skip.h) continue;
    const i = (Math.min(img.height - 1, Math.floor(fy * img.height)) * img.width + Math.min(img.width - 1, Math.floor(fx * img.width))) * 4;
    m[0] += img.data[i] ?? 0; m[1] += img.data[i + 1] ?? 0; m[2] += img.data[i + 2] ?? 0; n++;
  }
  return n ? [m[0] / n, m[1] / n, m[2] / n] : null;
}
const dist = (a: [number, number, number] | null, b: [number, number, number] | null) =>
  a && b ? (Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2])) / 765 : 1;
const lum = (c: [number, number, number] | null) => (c ? (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255 : 0);

/** The wall (the top of the frame and the sides above the floor) and the floor in front of the car. */
export const WALL: readonly FBox[] = [{ x: 0, y: 0, w: 1, h: 0.2 }, { x: 0, y: 0.2, w: 0.07, h: 0.45 }, { x: 0.93, y: 0.2, w: 0.07, h: 0.45 }];
export const floorOf = (t: FrameTarget): FBox => ({ x: 0, y: Math.min(0.97, t.bottom + 0.05), w: 1, h: Math.max(0.03, 1 - (t.bottom + 0.05)) });

export interface GateMeasures { zoom?: number; car?: FBox; wall?: number; floor?: number; shadow?: number }
export interface GateVerdict { pass: boolean; reasons: GateReason[]; measures: GateMeasures }

/** The gate on a normalized outside render: `img` and `plate` the same size (the frame), `car` the car's box in it. */
export function gateExterior(o: { shot: string; img: Rgba; plate: Rgba | null; car: FBox | null; view: string | null; nose: string | null; zoom?: number }): GateVerdict {
  const reasons: GateReason[] = [];
  const m: GateMeasures = {};
  const t = STUDIO_FRAME[o.shot];
  if (o.view !== o.shot) reasons.push('gate_wrong_view');
  const face = FACE[o.shot];
  if (face && o.nose !== face) reasons.push('gate_wrong_direction');
  if (!t) return { pass: !reasons.length, reasons, measures: m };
  if (!o.car) reasons.push('gate_no_car_box');
  else {
    m.car = { x: +o.car.x.toFixed(3), y: +o.car.y.toFixed(3), w: +o.car.w.toFixed(3), h: +o.car.h.toFixed(3) };
    if (o.zoom) m.zoom = +o.zoom.toFixed(3);
    const cx = o.car.x + o.car.w / 2, bottom = o.car.y + o.car.h;
    if (Math.abs(o.car.w - t.width) > FRAME_TOL.width || Math.abs(cx - t.cx) > FRAME_TOL.cx || Math.abs(bottom - t.bottom) > FRAME_TOL.bottom) reasons.push('gate_car_off_target');
  }
  if (!o.plate) reasons.push('gate_no_plate');
  else {
    const skip = o.car ? { x: o.car.x - 0.01, y: o.car.y - 0.01, w: o.car.w + 0.02, h: o.car.h + 0.02 } : null;
    const wall = WALL.reduce((s, r) => s + dist(regionMean(o.img, r, skip), regionMean(o.plate!, r, skip)), 0) / WALL.length;
    const fl = floorOf(t);
    const floor = dist(regionMean(o.img, fl, skip), regionMean(o.plate, fl, skip));
    m.wall = +wall.toFixed(3); m.floor = +floor.toFixed(3);
    if (wall > WALL_MAX) reasons.push('gate_wall_mismatch');
    if (floor > FLOOR_MAX) reasons.push('gate_floor_mismatch');
    if (o.car) {
      // the floor at the tyres' line and just below it, inside the car's width: darker than the empty plate there
      const under: FBox = { x: o.car.x + o.car.w * 0.15, y: Math.min(0.98, o.car.y + o.car.h - 0.005), w: o.car.w * 0.7, h: 0.017 };
      const shadow = lum(regionMean(o.plate, under)) - lum(regionMean(o.img, under));
      m.shadow = +shadow.toFixed(3);
      if (shadow < SHADOW_MIN) reasons.push('gate_no_shadow');
    }
  }
  return { pass: !reasons.length, reasons: [...new Set(reasons)], measures: m };
}

/** An inside view: the view only (no plate, no floor). */
export function gateInterior(o: { shot: string; view: string | null }): GateVerdict {
  const reasons: GateReason[] = o.view === o.shot ? [] : ['gate_wrong_view'];
  return { pass: !reasons.length, reasons, measures: {} };
}

/** The words for the image model: exactly where the car stands (a little smaller than the target, see FRAME_ASK). */
export function placementLine(shot: string): string {
  const t = STUDIO_FRAME[shot];
  if (!t) return '';
  const pct = (n: number) => Math.round(n * 100);
  return `EXACT PLACEMENT (the same for every car): the car is ${pct(t.width * FRAME_ASK)} percent of the frame width from bumper to bumper, centred left to right, its tyres touching the floor at ${pct(t.bottom)} percent of the frame height from the top, the whole car inside the frame with floor in front of it. The background is exactly the background plate, unchanged, the camera where the plate's camera is. A soft dark contact shadow under the car and under each tyre.`;
}
