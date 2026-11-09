// The showroom scene of the listing photos (release 35, migration 0990): the owner's ask "photos taken in a dealership with
// the CarmaCars logo behind instead of a black background with the cars floating; keep the dealership very simple and
// dark; the vehicle model behind the car in the first photo". The car's framed cut-out (subject-frame.ts) is placed in a
// plain dark showroom: a dark wall with a soft light behind the car, the CarmaCars logo high on the wall, a dark glossy
// floor with the car's soft reflection and its contact shadow. The cover (the first photo) also has the model's name
// lettered on the wall behind the car. Every angle of a car gets the same room.
//
// Two providers behind one interface (ShowroomProvider):
//   local: this file, pure and deterministic, no network and no cost (always there; the fallback for the other one)
//   ai:    an image model that makes the local scene look photographed (integrations/photos/gemini.ts), used when its key
//          is set, within its daily limit (Program settings), never past the free use; any refusal or error keeps the
//          local scene and the reason is shown to staff on the photo.
import jpeg from 'jpeg-js';
import glyphData from './presets/ghost-glyphs.json' with { type: 'json' };
import logoData from './presets/showroom-logo.json' with { type: 'json' };
import { letteringName } from '../car/studio.ts';
import { decodePng, type Rgba } from './subject-frame.ts';

export const SHOWROOM_PRESET = 'studio_showroom_v1';
export type Scene = 'studio' | 'showroom';
/** The scene a job's photo asks for (the database's vehicle_photos.scene); anything else is the black studio. */
export const sceneOf = (p: { scene?: unknown } | null | undefined): Scene => (p?.scene === 'showroom' ? 'showroom' : 'studio');

/** The room on the 1800 x 1200 frame: the wall meets the floor at junction, the wheels stand on the floor line (888). */
export const ROOM = { width: 1800, height: 1200, junction: 690, floorLine: 888,
  logo: { width: 500, top: 56 }, name: { maxWidth: 1500, capHeight: 250, baseline: 640 } } as const;

type Glyphs = { unitsPerEm: number; glyphs: Record<string, { advance: number; contours: number[][][] }> };
const G = glyphData as unknown as Glyphs;
type Logo = { viewBox: number[]; paths: Array<{ fill: number[]; polys: number[][] }> };
const L = logoData as unknown as Logo;

/** Coverage (0 to 1) of polygons (even-odd) on a W x H grid: 5 sub-rows a pixel, exact coverage across each row. */
export function fillPolys(polys: number[][], W: number, H: number): Float32Array {
  const m = new Float32Array(W * H);
  const SUB = 5;
  const edges: Array<[number, number, number, number]> = [];
  let minY = Infinity, maxY = -Infinity;
  for (const p of polys) {
    const n = p.length / 2;
    for (let i = 0; i < n; i++) {
      const x0 = p[i * 2]!, y0 = p[i * 2 + 1]!, x1 = p[((i + 1) % n) * 2]!, y1 = p[((i + 1) % n) * 2 + 1]!;
      if (y0 === y1) continue;
      edges.push([x0, y0, x1, y1]);
      minY = Math.min(minY, y0, y1); maxY = Math.max(maxY, y0, y1);
    }
  }
  const ya = Math.max(0, Math.floor(minY)), yb = Math.min(H - 1, Math.ceil(maxY));
  const xs: number[] = [];
  for (let y = ya; y <= yb; y++) {
    for (let s = 0; s < SUB; s++) {
      const sy = y + (s + 0.5) / SUB;
      xs.length = 0;
      for (const [x0, y0, x1, y1] of edges) {
        if ((sy >= y0 && sy < y1) || (sy >= y1 && sy < y0)) xs.push(x0 + ((sy - y0) * (x1 - x0)) / (y1 - y0));
      }
      if (xs.length < 2) continue;
      xs.sort((a, b) => a - b);
      for (let k = 0; k + 1 < xs.length; k += 2) {
        const a = Math.max(0, xs[k]!), b = Math.min(W, xs[k + 1]!);
        if (b <= a) continue;
        const ia = Math.floor(a), ib = Math.floor(b), row = y * W;
        if (ia === ib) { m[row + ia]! += (b - a) / SUB; continue; }
        m[row + ia]! += (ia + 1 - a) / SUB;
        for (let x = ia + 1; x < ib && x < W; x++) m[row + x]! += 1 / SUB;
        if (ib < W) m[row + ib]! += (b - ib) / SUB;
      }
    }
  }
  for (let i = 0; i < m.length; i++) if (m[i]! > 1) m[i] = 1;
  return m;
}

/** The model's name as polygons on the frame (Inter 800), centred, at most maxWidth wide and capHeight high. */
export function namePolys(model: string, W = ROOM.width): number[][] {
  const text = letteringName(model ?? '');
  if (!text) return [];
  const adv = [...text].reduce((a, ch) => a + (G.glyphs[ch]?.advance ?? G.glyphs[' ']!.advance), 0);
  const size = Math.min(ROOM.name.maxWidth / (adv / G.unitsPerEm), ROOM.name.capHeight / 0.727);
  const s = size / G.unitsPerEm;
  let pen = (W - adv * s) / 2;
  const out: number[][] = [];
  for (const ch of text) {
    const g = G.glyphs[ch] ?? G.glyphs[' ']!;
    for (const c of g.contours) out.push(c.flatMap(([x, y]) => [pen + x! * s, ROOM.name.baseline - y! * s]));
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
const cache = new Map<string, Uint8ClampedArray>();

/** The empty room (RGBA, opaque): the wall, its light, the logo, on the cover the model's name, the floor. Deterministic. */
export function showroomBackdrop(o: { model?: string | null; cover?: boolean } = {}): Rgba {
  const W = ROOM.width, H = ROOM.height, J = ROOM.junction;
  const name = o.cover && o.model ? letteringName(o.model) : '';
  const key = `v1:${name}`;
  const hit = cache.get(key);
  if (hit) return { width: W, height: H, data: new Uint8ClampedArray(hit) };
  const d = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const side = Math.abs(x - W / 2) / (W / 2);
      let v: number;
      if (y < J) {
        // the wall: charcoal, a little lighter low down, a soft light behind the car, darker at the sides
        const t = y / J;
        const glow = Math.exp(-(((x - W / 2) / 760) ** 2 + ((y - 400) / 430) ** 2));
        v = 22 + 14 * t + 24 * glow - 10 * side * side;
        if (y >= J - 7) v = 17;                  // the skirting where the wall meets the floor
      } else {
        // the floor: dark and glossy, the wall's light faintly mirrored near the wall, darker towards the camera
        const t = (y - J) / (H - J);
        const sheen = Math.exp(-(((x - W / 2) / 700) ** 2 + (t / 0.28) ** 2));
        v = 15 - 8 * t + 12 * sheen - 6 * side * side;
        if (y === J) v = 46;                      // a thin catch of light on the floor's edge
      }
      d[i] = clamp(v); d[i + 1] = clamp(v + 1); d[i + 2] = clamp(v + 4); d[i + 3] = 255;
    }
  }
  const over = (mask: Float32Array, rgb: number[], alpha: number) => {
    for (let p = 0; p < mask.length; p++) {
      const a = mask[p]! * alpha;
      if (!a) continue;
      const i = p * 4;
      d[i] = d[i]! + (rgb[0]! - d[i]!) * a; d[i + 1] = d[i + 1]! + (rgb[1]! - d[i + 1]!) * a; d[i + 2] = d[i + 2]! + (rgb[2]! - d[i + 2]!) * a;
    }
  };
  // the model's name on the wall behind the car (the cover only): large brushed letters, quiet against the wall
  if (name) over(fillPolys(namePolys(name), W, H), [205, 208, 214], 0.11);
  // the logo, lit
  for (const p of logoPaths()) over(fillPolys(p.polys, W, H), p.fill, p.fill[0] === 255 && p.fill[1] === 255 ? 0.9 : 1);
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
 *  `place` (as placeSubject gives it: from the frame's bottom edge), with its reflection on the floor. Pure. */
export function composeShowroom(car: Rgba & { ground: number }, place: Place, o: { model?: string | null; cover?: boolean } = {}): Rgba {
  const room = showroomBackdrop(o);
  const W = room.width, H = room.height, d = room.data;
  const top = H - place.bottom - place.height;
  const wheel = top + place.height * (1 - car.ground);
  const carH = wheel - top;
  const sx = car.width / place.width, sy = car.height / place.height;
  const px = [0, 0, 0, 0];
  const x0 = Math.max(0, Math.floor(place.left)), x1 = Math.min(W, Math.ceil(place.left + place.width));
  // the reflection: the car mirrored at its wheel line, faint and darker, fading out over 40% of its height
  const R = Math.min(carH * 0.4, H - wheel);
  for (let y = Math.max(0, Math.ceil(wheel)); y < Math.min(H, wheel + R); y++) {
    const dd = y - wheel, f = 0.26 * (1 - dd / R) ** 1.6;
    const srcY = (wheel - dd - top) * sy - 0.5;
    if (srcY < 0) continue;
    for (let x = x0; x < x1; x++) {
      sample(car, (x - place.left) * sx - 0.5, srcY, px);
      const a = px[3]! * f;
      if (a <= 0.002) continue;
      const i = (y * W + x) * 4;
      d[i] = d[i]! + (px[0]! * 0.7 - d[i]!) * a; d[i + 1] = d[i + 1]! + (px[1]! * 0.7 - d[i + 1]!) * a; d[i + 2] = d[i + 2]! + (px[2]! * 0.7 - d[i + 2]!) * a;
    }
  }
  // the car with its contact shadow
  for (let y = Math.max(0, Math.floor(top)); y < Math.min(H, Math.ceil(top + place.height)); y++) {
    const srcY = (y - top) * sy - 0.5;
    for (let x = x0; x < x1; x++) {
      sample(car, (x - place.left) * sx - 0.5, srcY, px);
      const a = px[3]!;
      if (a <= 0.002) continue;
      const i = (y * W + x) * 4;
      d[i] = d[i]! + (px[0]! - d[i]!) * a; d[i + 1] = d[i + 1]! + (px[1]! - d[i + 1]!) * a; d[i + 2] = d[i + 2]! + (px[2]! - d[i + 2]!) * a;
    }
  }
  return room;
}

/** An image scaled to cover W x H and centred (an image model answers in its own size). */
export function fitFrame(img: Rgba, W = ROOM.width, H = ROOM.height): Rgba {
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
export type ShowroomFailure = 'no_key' | 'off' | 'limit' | 'quota' | 'model' | 'blocked' | 'timeout' | 'error';
export type ShowroomOut =
  | { ok: true; bytes: Uint8Array; contentType: string; provider: 'local' | 'ai'; model?: string }
  | { ok: false; reason: ShowroomFailure; message: string };
export interface ShowroomInput { car: Rgba & { ground: number }; place: Place; model?: string | null; cover: boolean; photoId: string }
/** One way of making the showroom photo; swappable (the worker takes any list, the last is the local one). */
export interface ShowroomProvider { readonly name: string; make(i: ShowroomInput, local: Uint8Array): Promise<ShowroomOut> }

/** The free local composite: always answers. */
export const localShowroom = {
  name: 'local',
  make(i: ShowroomInput): ShowroomOut {
    return { ok: true, bytes: encodeJpeg(composeShowroom(i.car, i.place, { model: i.model, cover: i.cover })), contentType: 'image/jpeg', provider: 'local' };
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
  error: 'Made with the free showroom: the image model failed.'
};

/** The local scene, then the providers in turn (the first that answers wins); the local scene when none does, with why. */
export async function makeShowroom(i: ShowroomInput, providers: ShowroomProvider[], noKey = false): Promise<{ bytes: Uint8Array; contentType: string; provider: 'local' | 'ai'; model?: string; note: string | null; reason: ShowroomFailure | null }> {
  const local = localShowroom.make(i) as Extract<ShowroomOut, { ok: true }>;
  let last: Extract<ShowroomOut, { ok: false }> | null = noKey && !providers.length ? { ok: false, reason: 'no_key', message: 'no key' } : null;
  for (const p of providers) {
    let r: ShowroomOut;
    try { r = await p.make(i, local.bytes); } catch (e) { r = { ok: false, reason: 'error', message: e instanceof Error ? e.message : String(e) }; }
    if (r.ok) {
      // an image model answers in its own size: fitted to the frame so every photo of the car is the same size
      const img = await decodeImage(r.bytes).catch(() => null);
      if (img) return { bytes: encodeJpeg(fitFrame(img)), contentType: 'image/jpeg', provider: r.provider, ...(r.model ? { model: r.model } : {}), note: null, reason: null };
      last = { ok: false, reason: 'blocked', message: 'The image could not be read' };
      continue;
    }
    last = r;
  }
  return { bytes: local.bytes, contentType: local.contentType, provider: 'local', note: last ? FALLBACK_TEXT[last.reason] : null, reason: last?.reason ?? null };
}

/** The instruction for the image model: the local scene made to look photographed, nothing else changed. */
export function showroomPrompt(o: { cover: boolean; name?: string | null }): string {
  return [
    'This is a photo of a car standing in a simple, dark car showroom. Make it look like a real professional photograph taken in that showroom.',
    'Keep the car exactly as it is: its shape, colour, wheels, badges, every detail, its position and its size in the frame. Do not redraw or move it.',
    'Keep the room very simple and dark: a plain dark wall and a dark glossy floor. Keep the logo on the wall exactly as it is, in the same place.',
    o.cover && o.name ? `Keep the large lettering "${o.name}" on the wall behind the car exactly as it is.` : 'Do not add any lettering.',
    'Give the floor a soft, realistic reflection of the car and a soft contact shadow under the tyres, with soft showroom lighting on the car.',
    'Any licence plate stays plain with no readable letters or numbers.',
    'Do not add other cars, people, signs, text, watermarks or objects. Keep the same framing, landscape 3:2.'
  ].join(' ');
}
