// The showroom scene of the listing photos (release 35, migrations 0990 and 1050): the owner's ask "photos taken in a
// dealership with the CarmaCars logo behind instead of a black background with the cars floating; keep the dealership very
// simple and dark; the vehicle model behind the car in the first photo", then (v2) "that is not what a showroom looks like,
// make it better". The car's framed cut-out (subject-frame.ts) is placed in a simple dark dealership drawn here in one-point
// perspective: recessed linear lights in the ceiling, a back wall washed by a cove light with a slatted walnut feature
// panel between two vertical light strips, the CarmaCars logo as a large lit sign with its glow (the wall's main feature), plain side walls, a polished dark
// tiled floor that mirrors the room softly, a soft shadow under the car and a contact shadow under each tyre, a vignette.
// The cover (the first photo) also has the model's name in brushed metal letters on the wall, above the car when there is
// room and behind it otherwise (never over it). Every angle of a car gets the same room. Preset studio_showroom_v2.
//
// Two providers behind one interface (ShowroomProvider):
//   local: this file, pure and deterministic, no network and no cost (always there; the fallback for the other one)
//   ai:    an image model that makes the local scene look photographed (integrations/photos/gemini.ts), used when its key
//          is set, within its daily limit (Program settings), never past the free use; any refusal or error keeps the
//          local scene and the reason is shown to staff on the photo. It may relight the car, clean its paint or turn it
//          slightly; an answer that is not clearly the same car (model, colour, shape) is not used (sameCar).
import jpeg from 'jpeg-js';
import glyphData from './presets/ghost-glyphs.json' with { type: 'json' };
import logoData from './presets/showroom-logo.json' with { type: 'json' };
import { letteringName } from '../car/studio.ts';
import { SHOWROOM_FIT, decodePng, type Rgba } from './subject-frame.ts';
import { fillPolys } from './raster.ts';

export const SHOWROOM_PRESET = 'studio_showroom_v2';
export type Scene = 'studio' | 'showroom';
/** The scene a job's photo asks for (the database's vehicle_photos.scene); anything else is the black studio. */
export const sceneOf = (p: { scene?: unknown } | null | undefined): Scene => (p?.scene === 'showroom' ? 'showroom' : 'studio');

/** v2: the car a little smaller than on the black studio so the room shows around it (placeSubject's fit). */
export { SHOWROOM_FIT };

/** The room on the 1800 x 1200 frame, one-point perspective. The vanishing point is (900, horizon); the back wall spans
 *  wallLeft..wallRight from the ceiling line down to the junction with the floor; the side walls run from its corners to the
 *  frame's edges; the wheels stand on floorLine (SHOWROOM_FIT.floor). The logo is a lit sign high on a slatted feature
 *  panel; on the cover the model's name is lettered on the wall under it, above the car when there is room. */
export const ROOM = { width: 1800, height: 1200, horizon: 560, ceiling: 120, junction: 700, wallLeft: 210, wallRight: 1590,
  panel: { left: 380, right: 1420 }, floorLine: 960,
  logo: { width: 900, top: 146 }, name: { maxWidth: 1100, top: 338, capMin: 84, capMax: 140, gap: 26 } } as const;
const VX = ROOM.width / 2, DW = VX - ROOM.wallLeft;

type Glyphs = { unitsPerEm: number; glyphs: Record<string, { advance: number; contours: number[][][] }> };
const G = glyphData as unknown as Glyphs;
type Logo = { viewBox: number[]; paths: Array<{ fill: number[]; polys: number[][] }> };
const L = logoData as unknown as Logo;

export { fillPolys };

/** Where the model's name goes on the cover: its cap top and height. Above the car when the car leaves room (the car's top
 *  at carTop), never smaller than capMin (then the car stands in front of the letters' feet, as in a showroom). */
export function nameBox(carTop: number | null | undefined): { top: number; cap: number } {
  const room = (carTop ?? ROOM.junction) - ROOM.name.gap - ROOM.name.top;
  return { top: ROOM.name.top, cap: Math.round(Math.min(ROOM.name.capMax, Math.max(ROOM.name.capMin, room))) };
}

/** The model's name as polygons on the frame (Inter 800), centred, at most maxWidth wide, its capitals `cap` high from `top`. */
export function namePolys(model: string, W = ROOM.width, box = nameBox(null)): number[][] {
  const text = letteringName(model ?? '');
  if (!text) return [];
  const adv = [...text].reduce((a, ch) => a + (G.glyphs[ch]?.advance ?? G.glyphs[' ']!.advance), 0);
  const size = Math.min(ROOM.name.maxWidth / (adv / G.unitsPerEm), box.cap / 0.727);
  const s = size / G.unitsPerEm, baseline = box.top + size * 0.727;
  let pen = (W - adv * s) / 2;
  const out: number[][] = [];
  for (const ch of text) {
    const g = G.glyphs[ch] ?? G.glyphs[' ']!;
    for (const c of g.contours) out.push(c.flatMap(([x, y]) => [pen + x! * s, baseline - y! * s]));
    pen += g.advance * s;
  }
  return out;
}

/** The logo's paths on the frame: centred, ROOM.logo.width wide, its top at ROOM.logo.top. */
export function logoPaths(W = ROOM.width): Array<{ fill: number[]; polys: number[][] }> {
  const [vx, vy, vw] = L.viewBox as [number, number, number, number];
  const k = ROOM.logo.width / vw, ox = (W - ROOM.logo.width) / 2, oy = ROOM.logo.top;
  return L.paths.map((p) => ({ fill: p.fill, polys: p.polys.map((poly) => poly.map((v, i) => (i % 2 === 0 ? ox + (v - vx) * k : oy + (v - vy) * k))) }));
}

const clamp = (v: number) => (v < 0 ? 0 : v > 255 ? 255 : v);
/** A small integer hash in [0, 1): the slats' grain, the same on every run. */
const hash = (a: number, b = 0) => { let h = Math.imul(a ^ 0x9e3779b9, 0x85ebca6b) ^ Math.imul(b + 0x632be5ab, 0xc2b2ae35); h ^= h >>> 13; h = Math.imul(h, 0x27d4eb2f); h ^= h >>> 16; return (h >>> 0) / 4294967296; };
/** The ceiling line and the floor line at column x (the back wall's between wallLeft and wallRight; the side walls' beyond). */
const lines = (x: number) => {
  const d = Math.abs(x - VX);
  if (d <= DW) return [ROOM.ceiling, ROOM.junction] as const;
  return [ROOM.horizon - (ROOM.horizon - ROOM.ceiling) * d / DW, ROOM.horizon + (ROOM.junction - ROOM.horizon) * d / DW] as const;
};

/** Three box blurs (close to a Gaussian of about r) of a mask, in place. */
function blurMask(m: Float32Array, w: number, h: number, r: number) {
  const tmp = new Float32Array(Math.max(w, h));
  for (let pass = 0; pass < 3; pass++) {
    for (let y = 0; y < h; y++) {
      let acc = 0; const row = y * w;
      for (let x = -r; x < w + r; x++) {
        if (x + r < w) acc += m[row + Math.min(w - 1, x + r)]!; else acc += 0;
        if (x - r - 1 >= 0) acc -= m[row + x - r - 1]!;
        if (x >= 0 && x < w) tmp[x] = acc / (2 * r + 1);
      }
      for (let x = 0; x < w; x++) m[row + x] = tmp[x]!;
    }
    for (let x = 0; x < w; x++) {
      let acc = 0;
      for (let y = -r; y < h + r; y++) {
        if (y + r < h) acc += m[(y + r) * w + x]!;
        if (y - r - 1 >= 0) acc -= m[(y - r - 1) * w + x]!;
        if (y >= 0 && y < h) tmp[y] = acc / (2 * r + 1);
      }
      for (let y = 0; y < h; y++) m[y * w + x] = tmp[y]!;
    }
  }
}

const cache = new Map<string, Uint8ClampedArray>();

/** The empty room (RGBA, opaque), deterministic: a dark ceiling with recessed linear lights, a charcoal back wall washed by
 *  a cove light with a slatted wood feature panel between two vertical light strips, the CarmaCars logo as a lit sign with
 *  its glow, on the cover the model's name in brushed metal letters, plain side walls, and a polished dark floor (large
 *  tiles) that mirrors the wall softly; a gentle vignette. `carTop` places the name above the car when there is room. */
export function showroomBackdrop(o: { model?: string | null; cover?: boolean; carTop?: number | null } = {}): Rgba {
  const W = ROOM.width, H = ROOM.height, C = ROOM.ceiling, J = ROOM.junction, HZ = ROOM.horizon;
  const name = o.cover && o.model ? letteringName(o.model) : '';
  const box = nameBox(o.carTop);
  const key = `v2:${name}:${name ? box.cap : 0}`;
  const hit = cache.get(key);
  if (hit) return { width: W, height: H, data: new Uint8ClampedArray(hit) };
  // the room above the floor in floating point (the floor mirrors it)
  const TOPH = Math.ceil(lines(0)[1]) + 2;
  // per column and per row tables (the loops below stay free of exp and of allocations)
  const YC = new Float32Array(W), YF = new Float32Array(W), PX = new Float32Array(W), FX = new Float32Array(W), VXq = new Float32Array(W);
  for (let x = 0; x < W; x++) { const [a, b] = lines(x); YC[x] = a; YF[x] = b; PX[x] = Math.exp(-(((x - VX) / 560) ** 2)); FX[x] = Math.exp(-(((x - VX) / 620) ** 2)); VXq[x] = ((x - VX) / 1050) ** 2; }
  const PY = new Float32Array(H), FY = new Float32Array(H), VYq = new Float32Array(H), E150 = new Float32Array(H + 1), E260 = new Float32Array(H + 1), C64 = new Float32Array(H + 1), C220 = new Float32Array(H + 1);
  for (let y = 0; y < H; y++) { PY[y] = Math.exp(-(((y - 470) / 230) ** 2)); FY[y] = Math.exp(-(((y - 930) / 200) ** 2)); VYq[y] = ((y - 600) / 820) ** 2; }
  for (let k = 0; k <= H; k++) { E150[k] = Math.exp(-k / 150); E260[k] = Math.exp(-k / 260); C64[k] = Math.exp(-k / 64); C220[k] = Math.exp(-k / 220); }
  const VG = new Float32Array(1025);
  for (let k = 0; k <= 1024; k++) VG[k] = 1 - 0.4 * (k / 1024) ** 1.4;
  const f = new Float32Array(W * TOPH * 3);
  const PL = ROOM.panel.left, PR = ROOM.panel.right;
  for (let x = 0; x < W; x++) {
    const yc = YC[x]!, yf = YF[x]!;
    const d = Math.abs(x - VX), back = d <= DW;
    const depth = back ? 1 : DW / d;                         // 1 at the back wall, smaller towards the camera
    for (let y = 0; y < TOPH; y++) {
      const i = (y * W + x) * 3;
      let r: number, g: number, b: number;
      if (y < yc) {
        // the ceiling: near black, two linear lights running to the back and one across, each with a soft glow
        let v = 7 + 5 * (y / Math.max(1, yc));
        let led = 0;
        const k = (HZ - y) / (HZ - C);                         // the ceiling's scale at this row (1 at the back wall)
        for (let li = 0; li < 2; li++) {
          const xb = li ? 1240 : 560, xc = VX + (xb - VX) * k, hw = 2.6 * k, dd = Math.abs(x - xc);
          led += dd < hw ? 1 : Math.exp(-(((dd - hw) / (7 * k)) ** 2)) * 0.32;
        }
        for (let li = 0; li < 2; li++) {
          const yl = li ? 14 : 64;
          const th = 3 + (C - yl) * 0.03, dd = Math.abs(y - yl), half = (DW * (HZ - yl)) / (HZ - C) * 0.9;
          if (Math.abs(x - VX) < half) led += dd < th / 2 ? 1 : Math.exp(-(((dd - th / 2) / (th * 2.4)) ** 2)) * 0.3;
        }
        v += Math.min(1, led) * 228;
        r = v; g = v * 0.985; b = v * 0.96;
      } else if (y < yf) {
        // the cove light washes down from the ceiling line; a soft pool of light behind the car; darker low down
        const t = (y - yc) / Math.max(1, yf - yc);
        const dy = Math.min(H, Math.round((y - yc) / depth));
        const cove = 44 * C64[dy]! + 13 * C220[dy]!;
        const pool = back ? 15 * PX[x]! * PY[y]! : 0;
        let v = 16 + cove + pool - 5 * t - (back ? 0 : 4 * (1 - depth));
        if (y < yc + 3) v = 150 + 60 * depth;                  // the cove's own lit edge
        if (back && x >= PL && x < PR && y >= yc + 3 && y < yf - 10) {
          // the feature panel: vertical walnut slats with shadow gaps, each a little different, a faint grain
          const u = (x - PL) % 18, k = Math.floor((x - PL) / 18);
          if (u < 3) v *= 0.38;
          else v = v * 1.06 + (hash(k) - 0.5) * 5 + (hash(k, y >> 3) - 0.5) * 2.4 - 2.2 * Math.abs(u - 10.5) / 7.5;
          r = v * 1.13; g = v * 0.98; b = v * 0.84;
        } else { r = v; g = v + 0.6; b = v * 1.05 + 1.5; }
        if (y >= yf - 10) { const s = y >= yf - 7 ? 0.45 : 1.25; r *= s; g *= s; b *= s; }  // the shadow gap of the skirting, its lit lip
        if (back && y > yc + 18 && y < yf - 18) {
          // two vertical light strips at the panel's edges
          const dd = Math.min(Math.abs(x - (PL - 9)), Math.abs(x - (PR + 8)));
          const a = dd < 2 ? 1 : Math.exp(-(((dd - 2) / 11) ** 2)) * 0.5;
          r += (250 - r) * a; g += (240 - g) * a; b += (222 - b) * a;
        }
      } else { r = g = b = 0; }
      f[i] = r; f[i + 1] = g; f[i + 2] = b;
    }
  }
  const over = (mask: Float32Array, mw: number, ox: number, oy: number, rgb: (x: number, y: number) => readonly [number, number, number], alpha: number) => {
    const mh = mask.length / mw;
    for (let y = 0; y < mh; y++) for (let x = 0; x < mw; x++) {
      const a = mask[y * mw + x]! * alpha, fx = ox + x, fy = oy + y;
      if (!a || fx < 0 || fx >= W || fy < 0 || fy >= TOPH) continue;
      const i = (fy * W + fx) * 3, c = rgb(fx, fy);
      f[i] = f[i]! + (c[0] - f[i]!) * a; f[i + 1] = f[i + 1]! + (c[1] - f[i + 1]!) * a; f[i + 2] = f[i + 2]! + (c[2] - f[i + 2]!) * a;
    }
  };
  // a mask of polygons cut to a box of the frame (the fill works on the box only)
  const boxMask = (polys: number[][], x0: number, y0: number, w: number, h: number) => fillPolys(polys.map((p) => p.map((v, i) => (i % 2 === 0 ? v - x0 : v - y0))), w, h);
  // the model's name: brushed metal letters standing off the wall (their shadow first)
  if (name) {
    const polys = namePolys(name, W, box);
    const x0 = 120, y0 = box.top - 20, w = W - 240, h = box.cap + 70;
    const m = boxMask(polys, x0, y0, w, h);
    const sh = new Float32Array(m); blurMask(sh, w, h, 3);
    over(sh, w, x0 + 4, y0 + 8, () => [4, 4, 5], 0.75);
    over(m, w, x0, y0, (x, y) => { const t = (y - box.top) / box.cap, v = 112 - 48 * t + (hash(x >> 1, 7) - 0.5) * 5; return [v, v + 1, v + 4]; }, 0.92);
  }
  // the logo: a lit sign, its glow on the wall behind
  {
    const lhLogo = Math.ceil((ROOM.logo.width * L.viewBox[3]!) / L.viewBox[2]!);
    const paths = logoPaths(W), lw = ROOM.logo.width + 200, lh = lhLogo + 200, x0 = Math.round((W - lw) / 2), y0 = ROOM.logo.top - 100;
    const all = new Float32Array(lw * lh);
    const masks = paths.map((p) => { const m = boxMask(p.polys, x0, y0, lw, lh); for (let k = 0; k < m.length; k++) all[k] = Math.min(1, all[k]! + m[k]!); return m; });
    blurMask(all, lw, lh, 30);
    over(all, lw, x0, y0, () => [255, 246, 236], 0.85);
    paths.forEach((p, k) => over(masks[k]!, lw, x0, y0, () => (p.fill[0] === 255 && p.fill[1] === 255 ? [246, 246, 248] : [236, 26, 36]), 1));
  }
  // the floor: polished, dark, large tiles; it mirrors what stands above it, softly (blurred more further from the wall)
  const pre = new Float32Array((TOPH + 1) * W * 3);             // column prefix sums of the room above the floor
  for (let y = 0; y < TOPH; y++) for (let x = 0; x < W; x++) for (let c = 0; c < 3; c++) {
    pre[((y + 1) * W + x) * 3 + c] = pre[(y * W + x) * 3 + c]! + f[(y * W + x) * 3 + c]!;
  }
  const d = new Uint8ClampedArray(W * H * 4);
  const FOC = 1500, CAM = 1.2, ZB = (FOC * CAM) / (J - HZ);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o4 = (y * W + x) * 4;
      const yf = YF[x]!;
      let r: number, g: number, b: number;
      if (y < yf && y < TOPH) {
        const i = (y * W + x) * 3; r = f[i]!; g = f[i + 1]!; b = f[i + 2]!;
      } else {
        const below = y - yf;
        const z = (FOC * CAM) / Math.max(1, y - HZ);              // the floor's depth here (metres)
        // the floor's own sheen: brighter near the wall, a pool of overhead light where the car stands
        const bi = Math.min(H, Math.max(0, Math.round(below)));
        const base = 8 + 7 * E150[bi]! + 11 * FX[x]! * FY[y]!;
        // the mirror image: rows mirrored about the floor line, a vertical box blur and three columns
        const my = Math.max(0, Math.min(TOPH - 1, Math.round(2 * yf - y)));
        const rad = Math.min(70, Math.round(3 + below * 0.12));
        const a0 = Math.max(0, my - rad), a1 = Math.min(TOPH, my + rad + 1);
        let rr = 0, rg = 0, rb = 0;
        for (let dx = -6; dx <= 6; dx += 6) {
          const xx = x + dx < 0 ? 0 : x + dx >= W ? W - 1 : x + dx;
          rr += pre[(a1 * W + xx) * 3]! - pre[(a0 * W + xx) * 3]!;
          rg += pre[(a1 * W + xx) * 3 + 1]! - pre[(a0 * W + xx) * 3 + 1]!;
          rb += pre[(a1 * W + xx) * 3 + 2]! - pre[(a0 * W + xx) * 3 + 2]!;
        }
        const n = 3 * (a1 - a0);
        const k = 0.24 * E260[bi]! + 0.04;
        r = base * (1 - k * 0.5) + (rr / n) * k; g = base * (1 - k * 0.5) + (rg / n) * k + 0.3; b = base * (1 - k * 0.5) + (rb / n) * k + 1.2;
        // the tiles' seams (1.2 m), fading out towards the wall
        const X = ((x - VX) * z) / FOC, gx = Math.abs(X - Math.round(X / 1.2) * 1.2) * FOC / z;
        const zz = ZB - Math.round((ZB - z) / 1.2) * 1.2, gy = Math.abs(y - (HZ + (FOC * CAM) / Math.max(0.5, zz)));
        const seam = Math.max(gx < 0.8 ? 1 - gx / 0.8 : 0, gy < 0.8 ? 1 - gy / 0.8 : 0) * Math.min(1, below / 120);
        if (seam > 0) { const s = 1 - 0.16 * seam; r *= s; g *= s; b *= s; }
      }
      // a gentle vignette
      const vg = VG[Math.round(Math.min(1, VXq[x]! + VYq[y]!) * 1024)]!;
      d[o4] = clamp(r * vg); d[o4 + 1] = clamp(g * vg); d[o4 + 2] = clamp(b * vg); d[o4 + 3] = 255;
    }
  }
  cache.set(key, d);
  if (cache.size > 24) cache.delete(cache.keys().next().value!);
  return { width: W, height: H, data: new Uint8ClampedArray(d) };
}

/** Bilinear sample of an RGBA image at (x, y) in its pixel space; out of range is clear. */
function sample(img: Rgba, x: number, y: number, out: number[]) {
  const { width: w, height: h, data } = img;
  const x0 = Math.floor(x), y0 = Math.floor(y), fx = x - x0, fy = y - y0;
  out[0] = out[1] = out[2] = out[3] = 0;
  for (let k = 0; k < 4; k++) {
    const xx = x0 + (k & 1), yy = y0 + (k >> 1);
    if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
    const wgt = ((k & 1) ? fx : 1 - fx) * ((k >> 1) ? fy : 1 - fy);
    const i = (yy * w + xx) * 4, a = data[i + 3]! * wgt;
    out[0]! += data[i]! * a; out[1]! += data[i + 1]! * a; out[2]! += data[i + 2]! * a; out[3]! += a;
  }
  if (out[3]! > 0) { out[0]! /= out[3]!; out[1]! /= out[3]!; out[2]! /= out[3]!; }
  out[3] = out[3]! / 255;
}

export interface Place { width: number; height: number; left: number; bottom: number }

/** The framed car (its cut-out with the contact shadow, `ground` the share of its height below the wheels) in the room at
 *  `place` (as placeSubject gives it: from the frame's bottom edge): a soft shadow under the whole car, a dark contact
 *  shadow where the tyres meet the floor, its reflection in the polished floor, then the car itself, its pixels untouched.
 *  Pure. */
export function composeShowroom(car: Rgba & { ground: number }, place: Place, o: { model?: string | null; cover?: boolean;
  /** r39: the floor's reflection (0.22 on the drawn floor); a photographed room's own strength */
  reflect?: number;
  /** r39: the car's light nudged towards a photographed room's (photo-room.ts lightMatch) */
  gain?: readonly [number, number, number] } = {}, backdrop?: Rgba | null): Rgba {
  const W = ROOM.width, H = ROOM.height;
  const top = H - place.bottom - place.height;
  const wheel = top + place.height * (1 - car.ground);
  const carH = wheel - top;
  // 1053: a marketing scene may bring its own room (the white studio)
  const room = backdrop ? { width: backdrop.width, height: backdrop.height, data: new Uint8ClampedArray(backdrop.data) } : showroomBackdrop({ ...o, carTop: top });
  const d = room.data;
  const sx = car.width / place.width, sy = car.height / place.height;
  const px = [0, 0, 0, 0];
  const x0 = Math.max(0, Math.floor(place.left)), x1 = Math.min(W, Math.ceil(place.left + place.width));
  const darken = (x: number, y: number, k: number) => { if (k <= 0 || y < 0 || y >= H || x < 0 || x >= W) return; const i = (y * W + x) * 4, m = 1 - Math.min(0.95, k); d[i] = d[i]! * m; d[i + 1] = d[i + 1]! * m; d[i + 2] = d[i + 2]! * m; };
  // where the body is (a tenth of its height above the wheels) and where the tyres touch (just above the wheel line)
  const body = new Float32Array(W), touch = new Float32Array(W);
  for (let x = x0; x < x1; x++) {
    sample(car, (x - place.left) * sx - 0.5, (wheel - carH * 0.1 - top) * sy - 0.5, px); body[x] = px[3]!;
    sample(car, (x - place.left) * sx - 0.5, (wheel - 3 - top) * sy - 0.5, px); touch[x] = px[3]! > 0.55 ? 1 : 0;
  }
  let bx0 = -1, bx1 = -1;
  for (let x = x0; x < x1; x++) if (body[x]! > 0.5) { if (bx0 < 0) bx0 = x; bx1 = x; }
  if (bx0 >= 0) {
    // the soft shadow of the whole car (ambient light blocked under it)
    const cx = (bx0 + bx1) / 2, rx = ((bx1 - bx0) / 2) * 1.06, ry = Math.max(16, carH * 0.07);
    for (let y = Math.floor(wheel - ry); y < Math.min(H, Math.ceil(wheel + ry * 2.2)); y++) {
      const ny = (y - wheel) / (y > wheel ? ry * 2.2 : ry);
      for (let x = Math.max(0, Math.floor(cx - rx)); x < Math.min(W, Math.ceil(cx + rx)); x++) {
        const q = ((x - cx) / rx) ** 2 + ny * ny;
        if (q < 1) darken(x, y, 0.7 * (1 - q) ** 1.5);
      }
    }
    // the contact shadow: dark and tight under each tyre, a little wider than the tread
    const sm = new Float32Array(W);
    for (let x = x0; x < x1; x++) { let s = 0, n = 0; for (let k = -9; k <= 9; k++) { const xx = x + k; if (xx >= x0 && xx < x1) { s += touch[xx]!; n++; } } sm[x] = n ? s / n : 0; }
    for (let y = Math.floor(wheel - 3); y < Math.min(H, Math.ceil(wheel + 14)); y++) {
      const t = 1 - (y - (wheel - 3)) / 17;
      for (let x = x0; x < x1; x++) if (sm[x]! > 0) darken(x, y, 0.88 * sm[x]! * t);
    }
  }
  // the reflection: the car mirrored at its wheel line in the polished floor, faint and darker, fading out over 45% of its height
  const R = Math.min(carH * 0.45, H - wheel);
  for (let y = Math.max(0, Math.ceil(wheel)); y < Math.min(H, wheel + R); y++) {
    const dd = y - wheel, f = (o.reflect ?? 0.22) * (1 - dd / R) ** 2;
    const srcY = (wheel - dd - top) * sy - 0.5;
    if (srcY < 0) continue;
    for (let x = x0; x < x1; x++) {
      sample(car, (x - place.left) * sx - 0.5, srcY, px);
      const a = px[3]! * f;
      if (a <= 0.002) continue;
      const i = (y * W + x) * 4;
      d[i] = d[i]! + (px[0]! * 0.62 - d[i]!) * a; d[i + 1] = d[i + 1]! + (px[1]! * 0.62 - d[i + 1]!) * a; d[i + 2] = d[i + 2]! + (px[2]! * 0.62 - d[i + 2]!) * a;
    }
  }
  // the car with its own contact shadow, as it is (r39: its light nudged towards a photographed room's)
  const [gr, gg, gb] = o.gain ?? [1, 1, 1];
  for (let y = Math.max(0, Math.floor(top)); y < Math.min(H, Math.ceil(top + place.height)); y++) {
    const srcY = (y - top) * sy - 0.5;
    for (let x = x0; x < x1; x++) {
      sample(car, (x - place.left) * sx - 0.5, srcY, px);
      const a = px[3]!;
      if (a <= 0.002) continue;
      const i = (y * W + x) * 4;
      d[i] = d[i]! + (Math.min(255, px[0]! * gr) - d[i]!) * a; d[i + 1] = d[i + 1]! + (Math.min(255, px[1]! * gg) - d[i + 1]!) * a; d[i + 2] = d[i + 2]! + (Math.min(255, px[2]! * gb) - d[i + 2]!) * a;
    }
  }
  return room;
}

/** The image model may relight the car, clean its paint or turn it slightly (owner, Nov 8), as long as it is clearly the
 *  same car. Compared with the local scene where the car stands (a box a little larger than the car): the colour of the
 *  car's middle (its hue and saturation; brightness may change within reason), and the coarse shape of the box (a 32 x 16
 *  grid of brightness, correlated) so a missing, different or distorted car is refused. Pure; null when it is the same car,
 *  else why not. */
export function sameCar(ai: Rgba, local: Rgba, car: Rgba & { ground: number }, place: Place): 'colour' | 'shape' | 'size' | null {
  const W = ROOM.width, H = ROOM.height;
  if (ai.width !== W || ai.height !== H || local.width !== W || local.height !== H) return 'size';
  const top = H - place.bottom - place.height, wheel = top + place.height * (1 - car.ground);
  const sx = car.width / place.width, sy = car.height / place.height, px = [0, 0, 0, 0];
  const cw = place.width, ch = wheel - top;
  // the colour of the car's middle: chromaticity of the mean, and brightness within a factor of about two
  let n = 0; const ma = [0, 0, 0], mb = [0, 0, 0];
  for (let y = Math.floor(top + ch * 0.25); y < top + ch * 0.85; y += 4) for (let x = Math.floor(place.left + cw * 0.25); x < place.left + cw * 0.75; x += 4) {
    if (x < 0 || x >= W || y < 0 || y >= H) continue;
    sample(car, (x - place.left) * sx - 0.5, (y - top) * sy - 0.5, px);
    if (px[3]! < 0.8) continue;
    const i = (y * W + x) * 4;
    for (let c = 0; c < 3; c++) { ma[c]! += ai.data[i + c]!; mb[c]! += local.data[i + c]!; }
    n++;
  }
  if (n < 30) return 'shape';
  const chroma = (m: number[]) => { const t = m[0]! + m[1]! + m[2]! + 1e-6; return [m[0]! / t, m[1]! / t, m[2]! / t]; };
  const ca = chroma(ma), cb = chroma(mb);
  const dChroma = Math.hypot(ca[0]! - cb[0]!, ca[1]! - cb[1]!, ca[2]! - cb[2]!);
  const la = (ma[0]! + ma[1]! + ma[2]!) / n / 3, lb = (mb[0]! + mb[1]! + mb[2]!) / n / 3;
  if (dChroma > 0.07 || la > lb * 2.2 + 20 || la < lb / 2.2 - 20) return 'colour';
  // the coarse shape: a grid over the car's box with a margin (a slight turn or move still correlates)
  const bx = place.left - cw * 0.08, by = top - ch * 0.15, bw = cw * 1.16, bh = ch * 1.3, GX = 32, GY = 16;
  const A: number[] = [], B: number[] = [];
  for (let gy = 0; gy < GY; gy++) for (let gx = 0; gx < GX; gx++) {
    let sa = 0, sb = 0, k = 0;
    for (let y = Math.floor(by + (gy * bh) / GY); y < by + ((gy + 1) * bh) / GY; y += 3) for (let x = Math.floor(bx + (gx * bw) / GX); x < bx + ((gx + 1) * bw) / GX; x += 3) {
      if (x < 0 || x >= W || y < 0 || y >= H) continue;
      const i = (y * W + x) * 4;
      sa += ai.data[i]! * 0.299 + ai.data[i + 1]! * 0.587 + ai.data[i + 2]! * 0.114; sb += local.data[i]! * 0.299 + local.data[i + 1]! * 0.587 + local.data[i + 2]! * 0.114; k++;
    }
    if (k) { A.push(sa / k); B.push(sb / k); }
  }
  const mean = (v: number[]) => v.reduce((x, y) => x + y, 0) / v.length;
  const mA = mean(A), mB = mean(B);
  let sab = 0, saa = 0, sbb = 0;
  for (let i = 0; i < A.length; i++) { const a = A[i]! - mA, b = B[i]! - mB; sab += a * b; saa += a * a; sbb += b * b; }
  const corr = saa > 1e-6 && sbb > 1e-6 ? sab / Math.sqrt(saa * sbb) : 0;
  if (corr < 0.45) return 'shape';
  return null;
}

/** An image scaled to cover W x H and centred (an image model answers in its own size). */
export function fitFrame(img: Rgba, W: number = ROOM.width, H: number = ROOM.height): Rgba {
  if (img.width === W && img.height === H) return img;
  const k = Math.max(W / img.width, H / img.height);
  const ox = (img.width * k - W) / 2, oy = (img.height * k - H) / 2;
  const d = new Uint8ClampedArray(W * H * 4), px = [0, 0, 0, 0];
  const opaque: Rgba = img;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    sample(opaque, (x + ox + 0.5) / k - 0.5, (y + oy + 0.5) / k - 0.5, px);
    const i = (y * W + x) * 4;
    d[i] = px[0]!; d[i + 1] = px[1]!; d[i + 2] = px[2]!; d[i + 3] = 255;
  }
  return { width: W, height: H, data: d };
}

/** The frame as a JPEG (quality 88): the master the site's sizes are made from. */
export function encodeJpeg(img: Rgba, quality = 88): Uint8Array {
  const e = jpeg.encode({ width: img.width, height: img.height, data: img.data as unknown as Uint8Array }, quality);
  return new Uint8Array(e.data.buffer, e.data.byteOffset, e.data.byteLength);
}

/** A JPEG or PNG as RGBA; null when it cannot be read. */
export async function decodeImage(bytes: Uint8Array): Promise<Rgba | null> {
  if (bytes[0] === 0x89 && bytes[1] === 0x50) return decodePng(bytes);
  if (bytes[0] === 0xff && bytes[1] === 0xd8) {
    try {
      const j = jpeg.decode(bytes, { useTArray: true, formatAsRGBA: true, maxResolutionInMP: 40, maxMemoryUsageInMB: 400 });
      return { width: j.width, height: j.height, data: new Uint8ClampedArray(j.data.buffer, j.data.byteOffset, j.data.byteLength) };
    } catch { return null; }
  }
  return null;
}

// ================================================================ the providers
export type ShowroomFailure = 'no_key' | 'off' | 'limit' | 'quota' | 'model' | 'blocked' | 'timeout' | 'error' | 'changed';
export type ShowroomOut =
  | { ok: true; bytes: Uint8Array; contentType: string; provider: 'local' | 'ai'; model?: string }
  | { ok: false; reason: ShowroomFailure; message: string };
export interface ShowroomInput { car: Rgba & { ground: number }; place: Place; model?: string | null; cover: boolean; photoId: string;
  /** 1053, a marketing scene: the room drawn here (else the showroom), the image model's words, a photo of the real place */
  room?: Rgba | null; prompt?: string | null; reference?: { bytes: Uint8Array; contentType: string } | null;
  /** r39 (2400): a photographed room's floor reflection and the car's light matched to it (photo-room.ts) */
  look?: { reflect?: number; gain?: readonly [number, number, number] } | null }
/** One way of making the showroom photo; swappable (the worker takes any list, the last is the local one). */
export interface ShowroomProvider { readonly name: string; make(i: ShowroomInput, local: Uint8Array): Promise<ShowroomOut> }

/** The free local composite: always answers. */
export const localShowroom = {
  name: 'local',
  make(i: ShowroomInput): ShowroomOut {
    return { ok: true, bytes: encodeJpeg(composeShowroom(i.car, i.place, { model: i.model, cover: i.cover, ...(i.look ?? {}) }, i.room)), contentType: 'image/jpeg', provider: 'local' };
  }
};

/** What staff read under a photo when the local scene was used instead of the image model. */
export const FALLBACK_TEXT: Record<ShowroomFailure, string> = {
  no_key: 'Made with the free showroom: no image model key is set.',
  off: 'Made with the free showroom: the image model is switched off in Program settings.',
  limit: 'Made with the free showroom: today\'s image model limit (Program settings) is used. Redo it tomorrow for the photographed look.',
  quota: 'Made with the free showroom: the image model\'s free use is used up for now. Redo it later.',
  model: 'Made with the free showroom: the image model named in Program settings is not available to this key.',
  blocked: 'Made with the free showroom: the image model did not return a photo.',
  timeout: 'Made with the free showroom: the image model did not answer in time.',
  error: 'Made with the free showroom: the image model failed.',
  changed: 'Made with the free showroom: the image model showed a different car (model, colour or shape), so its photo was not used.'
};

/** The local scene, then the providers in turn (the first that answers with the car unchanged wins); the local scene when
 *  none does, with why. A model's photo is used as it is when it shows the same car (sameCar). */
export async function makeShowroom(i: ShowroomInput, providers: ShowroomProvider[], noKey = false): Promise<{ bytes: Uint8Array; contentType: string; provider: 'local' | 'ai'; model?: string; note: string | null; reason: ShowroomFailure | null }> {
  const scene = composeShowroom(i.car, i.place, { model: i.model, cover: i.cover, ...(i.look ?? {}) }, i.room);
  const local = { bytes: encodeJpeg(scene), contentType: 'image/jpeg' };
  let last: Extract<ShowroomOut, { ok: false }> | null = noKey && !providers.length ? { ok: false, reason: 'no_key', message: 'no key' } : null;
  for (const p of providers) {
    let r: ShowroomOut;
    try { r = await p.make(i, local.bytes); } catch (e) { r = { ok: false, reason: 'error', message: e instanceof Error ? e.message : String(e) }; }
    if (r.ok) {
      // an image model answers in its own size: fitted to the frame so every photo of the car is the same size
      const img = await decodeImage(r.bytes).catch(() => null);
      if (!img) { last = { ok: false, reason: 'blocked', message: 'The image could not be read' }; continue; }
      const fitted = fitFrame(img), why = sameCar(fitted, scene, i.car, i.place);
      if (why) { last = { ok: false, reason: 'changed', message: `Not the same car (${why})` }; continue; }
      return { bytes: encodeJpeg(fitted), contentType: 'image/jpeg', provider: r.provider, ...(r.model ? { model: r.model } : {}), note: null, reason: null };
    }
    last = r;
  }
  return { bytes: local.bytes, contentType: local.contentType, provider: 'local', note: last ? FALLBACK_TEXT[last.reason] : null, reason: last?.reason ?? null };
}

/** The instruction for the image model (Gemini first, the local scene is the fallback): the photo it is given is the car
 *  already standing in the CarmaCars showroom, drawn; it makes the room look photographed and leaves the car alone (the
 *  car's own pixels are put back afterwards, and a photo where the car moved is not used). */
export function showroomPrompt(o: { cover: boolean; name?: string | null }): string {
  return [
    'Edit this image into a real, high-end photograph of a car inside a modern, minimal, dark car dealership showroom at night.',
    'THE CAR: it must stay clearly the same car: the same make, model, generation, body style, trim, wheels and colour, about the same size and place in the frame, not cropped. You may improve how it looks: realistic showroom lighting and reflections on the paint, cleaned-up paint, and a slight change of pose or camera angle. Never change it into another car, another model or another colour, and never distort it.',
    'Do not add or show a licence plate, and never add letters or numbers on the car; where the plate area is plain or covered, leave it exactly so.',
    'THE ROOM (keep the same layout as the image, so every photo of this car shows the same room):',
    'a dark charcoal back wall meeting a polished dark floor at the same line as in the image, with the side walls and corners at the edges in the same perspective;',
    'a feature panel of vertical dark walnut wood slats in the middle of the back wall, with a thin vertical warm-white LED strip on each side of it;',
    'a cove light along the top of the back wall washing softly down it, and recessed linear LED light strips in the dark ceiling;',
    'the CarmaCars logo as a large illuminated sign, the dominant feature of the back wall: exactly the shapes and colours of the logo in the image, at least as large as in the image (about half the width of the wall panel), centred high on the wall above the car, its letters lit with a soft backlit glow on the wall behind them;',
    o.cover && o.name ? `the large brushed-metal lettering "${o.name}" on the wall exactly as in the image, behind the car and never in front of it;` : 'no lettering on the wall other than the logo: no model name, no car name, no words or numbers anywhere on the wall;',
    'a polished dark epoxy floor with faint large tiles, showing soft, blurred reflections of the wall lights and of the car, and a real, soft contact shadow under each tyre where it meets the floor.',
    'Light it like a professional dealership photo: soft overhead light, gentle falloff, a subtle vignette, realistic camera noise. Everything outside the car stays dark and minimal.',
    'Do not add other cars, people, furniture, plants, signs, text, watermarks or objects. Same framing, landscape 3:2.'
  ].join(' ');
}

/** r39 (2400): the image model's words for a car composited into a real photographed room: the room is a photo already,
 *  so it is kept as it is; only the car is blended in (light, reflections, contact shadow). */
export function photoRoomPrompt(): string {
  return [
    'This image is a real photograph of a car dealership interior with a car placed in it. Make it one seamless, real, high-end dealership photograph.',
    'THE ROOM: keep it exactly as it is: the same walls, floor, lights, windows and perspective. Do not add or remove anything in the room, and add no signs, logos or text.',
    'THE CAR: it must stay clearly the same car: the same make, model, generation, body style, trim, wheels and colour, about the same size and place in the frame, not cropped. Light it like the room (direction, colour and softness of the light), with believable reflections of the room on its paint and glass, a real soft contact shadow under each tyre on this floor and a faint reflection where the floor is polished. Never change it into another car, another model or another colour, and never distort it.',
    'Do not add or show a licence plate, and never add letters or numbers on the car; where the plate area is plain or covered, leave it exactly so.',
    'No people, no other cars, no watermarks. Same framing, landscape 3:2.'
  ].join(' ');
}

// ================================================================ 1053: marketing scenes
let white: Rgba | null = null;
/** The plain white studio of the marketing photos: a white wall fading into a light grey floor, soft light. Deterministic. */
export function whiteStudio(): Rgba {
  if (white) return { width: white.width, height: white.height, data: new Uint8ClampedArray(white.data) };
  const W = ROOM.width, H = ROOM.height, d = new Uint8ClampedArray(W * H * 4), J = 760;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4, side = ((x - VX) / VX) ** 2;
    const v = y < J ? 250 - 10 * (y / J) ** 2 - 6 * side : 236 - 30 * ((y - J) / (H - J)) - 10 * side + 8 * Math.exp(-(((y - J) / 60) ** 2));
    d[i] = clamp(v); d[i + 1] = clamp(v); d[i + 2] = clamp(v + 2); d[i + 3] = 255;
  }
  white = { width: W, height: H, data: d };
  return { width: W, height: H, data: new Uint8ClampedArray(d) };
}

/** The image model's words for a marketing scene: clearly the same car (it may be relit or turned slightly), the plate never shown, the place described
 *  (or the reference photo's place: same wall, ground and light). */
export function marketingPrompt(o: { label: string; place: string; reference: boolean }): string {
  return [
    `Edit this image into a real, high-end marketing photograph of the car in this place: ${o.place}.`,
    o.reference ? 'The second image is a photo of that real place: put the car in exactly that place, in front of the same building and wall, on the same ground, in the same light and weather. Do not copy any car, person or sign from it.' : '',
    'THE CAR: it must stay clearly the same car: the same make, model, generation, body style, trim, wheels and colour, about the same size and place in the frame, not cropped. You may relight it for the place, clean up the paint and change the pose or camera angle slightly. Never change it into another car, another model or another colour, and never distort it.',
    'Do not add or show a licence plate, and never add letters or numbers on the car; where the plate area is plain or covered, leave it exactly so.',
    'Give the car a real, soft contact shadow under each tyre on the ground and believable reflections for the place.',
    'Do not add other cars, people, signs, text, logos, watermarks or objects in front of the car. Landscape 3:2, the car where it is in the frame.'
  ].filter(Boolean).join(' ');
}

// ================================================================ r36 (2100): the listing's first photo with a model
/** The image model's words for the cover "with model": the owner's words from Program settings (listing_cover_model_prompt)
 *  inside the site's own rules, which no setting can loosen: one adult, fully clothed, nothing explicit or suggestive, the
 *  car unchanged and never covered. */
export function coverModelPrompt(settings: string | null | undefined, photoRoom = false): string {
  const words = (settings ?? '').replace(/\s+/g, ' ').trim().slice(0, 2000);
  return [
    'Edit this image into a real, high-end auto-show photograph of this car in this dark, modern showroom.',
    words,
    'RULES THAT ALWAYS APPLY: exactly one person, a clearly adult professional model (over 25 years old), fully clothed in a stylish outfit that covers the body; nothing revealing, see-through, explicit or sexual; no lingerie or swimwear; a natural, professional pose.',
    'THE CAR: it must stay clearly the same car: the same make, model, generation, body style, trim, wheels and colour, the same size and place in the frame, not cropped. The person stands beside it and never covers the car, its wheels, lights or badge. Never change it into another car or another colour, and never distort it.',
    'Do not add or show a licence plate, and never add letters or numbers on the car; where the plate area is plain or covered, leave it exactly so.',
    photoRoom ? 'Keep the room exactly as in the image (a real photograph): the same walls, floor and lights; add no signs, logos or text. No other people, cars, text or watermarks. Landscape 3:2.'
      : 'Keep the showroom as in the image: the CarmaCars logo sign on the wall exactly as it is, the dark walls and the polished floor with soft reflections. No other people, cars, text or watermarks. Landscape 3:2.'
  ].filter(Boolean).join(' ');
}
