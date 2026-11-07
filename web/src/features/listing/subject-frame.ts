// The studio framing of an outside photo (release 28, B8; preset studio_v3). The segmenter's cut-out is the whole frame
// with the car somewhere in it (often 40% of the width, wheels well above the bottom), and anything printed on the photo
// (another site's corner mark, a caption such as a model name) can come through as "foreground" too. Here, in the Worker:
//   1. the cut-out's pixels are read (8-bit RGBA or grey-alpha PNG, as the segmenter answers),
//   2. the car is the largest solid piece; small pieces away from it (the letters of a mark or a caption) are made clear,
//   3. the car is cropped to its own edges, with room below for a soft contact shadow drawn under it (darkest at the
//      tyres), so the compositor can place it at a set share of the frame with its wheels on the floor line.
// Pure and dependency free (the platform's CompressionStream / DecompressionStream); unit tested in subject-frame.test.ts.
import { statsOf, type PhotoStats } from './enhance.ts';

export interface Rgba { width: number; height: number; data: Uint8ClampedArray }
export interface Framed {
  png: Uint8Array; width: number; height: number;
  /** share of the image's height below the wheel line (the shadow) */
  ground: number;
  /** share of the image's width left empty on each side (the shadow's spread) */
  side: number;
  /** pieces made clear (a mark or a caption's letters) */
  dropped: number;
  /** the car's share of the cut-out's width and height before the crop (for the logs) */
  share: { w: number; h: number };
  /** r28 B9: the car's own pixels measured, for the touch-up (enhance.ts) */
  stats: PhotoStats;
}

const u32 = (b: Uint8Array, o: number) => ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0;

async function pipe(data: Uint8Array, s: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const out = new Response(new Blob([data as BlobPart]).stream().pipeThrough(s as unknown as ReadableWritablePair<Uint8Array, Uint8Array>));
  return new Uint8Array(await out.arrayBuffer());
}

/** The PNG's pixels as RGBA; null when it is not an 8-bit, non-interlaced PNG (RGBA, RGB, grey, grey-alpha or palette). */
export async function decodePng(png: Uint8Array): Promise<Rgba | null> {
  if (png.length < 33 || u32(png, 0) !== 0x89504e47 || u32(png, 4) !== 0x0d0a1a0a) return null;
  let o = 8, width = 0, height = 0, depth = 0, colour = 0, interlace = 0;
  const idat: Uint8Array[] = [];
  let plte: Uint8Array | null = null, trns: Uint8Array | null = null;
  while (o + 8 <= png.length) {
    const len = u32(png, o), type = String.fromCharCode(png[o + 4]!, png[o + 5]!, png[o + 6]!, png[o + 7]!);
    const body = png.subarray(o + 8, o + 8 + len);
    if (type === 'IHDR') { width = u32(body, 0); height = u32(body, 4); depth = body[8]!; colour = body[9]!; interlace = body[12]!; }
    else if (type === 'IDAT') idat.push(body);
    else if (type === 'PLTE') plte = body;
    else if (type === 'tRNS') trns = body;
    else if (type === 'IEND') break;
    o += 12 + len;
  }
  const bpp = colour === 6 ? 4 : colour === 4 ? 2 : colour === 2 ? 3 : colour === 0 || colour === 3 ? 1 : 0;
  if (colour === 3 && !plte) return null;
  if (!width || !height || width * height > 16_000_000 || depth !== 8 || !bpp || interlace !== 0 || !idat.length) return null;
  const joined = new Uint8Array(idat.reduce((n, c) => n + c.length, 0));
  let at = 0; for (const c of idat) { joined.set(c, at); at += c.length; }
  let raw: Uint8Array;
  try { raw = await pipe(joined, new DecompressionStream('deflate')); } catch { return null; }
  const stride = width * bpp;
  if (raw.length < height * (stride + 1)) return null;
  const data = new Uint8ClampedArray(width * height * 4);
  let prev = new Uint8Array(stride), cur = new Uint8Array(stride);
  for (let y = 0; y < height; y++) {
    const f = raw[y * (stride + 1)]!, line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp]! : 0, b = prev[x]!, c = x >= bpp ? prev[x - bpp]! : 0, v = line[x]!;
      let r: number;
      if (f === 0) r = v; else if (f === 1) r = v + a; else if (f === 2) r = v + b; else if (f === 3) r = v + ((a + b) >> 1);
      else if (f === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); r = v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c); }
      else return null;
      cur[x] = r & 0xff;
    }
    const row = y * width * 4;
    if (bpp === 4) data.set(cur, row);
    else for (let x = 0; x < width; x++) {
      const o4 = row + x * 4;
      if (colour === 4) { const g = cur[x * 2]!; data[o4] = g; data[o4 + 1] = g; data[o4 + 2] = g; data[o4 + 3] = cur[x * 2 + 1]!; }
      else if (colour === 2) { data[o4] = cur[x * 3]!; data[o4 + 1] = cur[x * 3 + 1]!; data[o4 + 2] = cur[x * 3 + 2]!; data[o4 + 3] = 255; }
      else if (colour === 0) { const g = cur[x]!; data[o4] = g; data[o4 + 1] = g; data[o4 + 2] = g; data[o4 + 3] = 255; }
      else { const k = cur[x]!; data[o4] = plte![k * 3] ?? 0; data[o4 + 1] = plte![k * 3 + 1] ?? 0; data[o4 + 2] = plte![k * 3 + 2] ?? 0; data[o4 + 3] = trns && k < trns.length ? trns[k]! : 255; }
    }
    [prev, cur] = [cur, prev];
  }
  return { width, height, data };
}

const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(parts: Uint8Array[]) { let c = 0xffffffff; for (const p of parts) for (let i = 0; i < p.length; i++) c = CRC[(c ^ p[i]!) & 0xff]! ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function chunk(type: string, body: Uint8Array) {
  const t = new TextEncoder().encode(type), out = new Uint8Array(12 + body.length), dv = new DataView(out.buffer);
  dv.setUint32(0, body.length); out.set(t, 4); out.set(body, 8); dv.setUint32(8 + body.length, crc32([t, body]));
  return out;
}

/** RGBA pixels as a PNG (the "sub" filter on every row: a cut-out is mostly clear, so it packs small). */
export async function encodePng(img: Rgba): Promise<Uint8Array> {
  const { width, height, data } = img, stride = width * 4;
  const raw = new Uint8Array(height * (stride + 1));
  for (let y = 0; y < height; y++) {
    const o = y * (stride + 1), row = y * stride;
    raw[o] = 1;
    for (let x = 0; x < stride; x++) raw[o + 1 + x] = (data[row + x]! - (x >= 4 ? data[row + x - 4]! : 0)) & 0xff;
  }
  const ihdr = new Uint8Array(13), dv = new DataView(ihdr.buffer);
  dv.setUint32(0, width); dv.setUint32(4, height); ihdr[8] = 8; ihdr[9] = 6;
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', await pipe(raw, new CompressionStream('deflate'))), chunk('IEND', new Uint8Array(0))];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0; for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

export const FRAME = {
  /** a pixel at or above this alpha is part of the subject (r31: was 48, which let the segmenter's faint haze, the floor's
   *  reflection and the soft shadow under the car count as car: the "car" was then the whole frame, nothing was cropped and
   *  the car came out a quarter of the width, floating above the floor line) */
  solid: 128,
  /** r31: when the subject still spans nearly the whole cut-out at that alpha, firmer ones are tried in turn */
  firmer: [192, 232],
  /** r31: a subject this share of the cut-out's width and height (or more) is haze around the car, not the car */
  hazeShare: 0.96,
  /** r31: a firmer alpha is taken while the car keeps at least this share of its cells */
  firmKeeps: 0.5,
  /** r31: rows and columns at the subject's edges holding less than this share of its fullest row or column are trimmed
   *  (specks of haze or reflection touching the car) */
  trim: 0.02,
  /** the size of the cells the pieces are found on */
  cell: 4,
  /** a piece outside the car's box is kept only when it is at least this share of the car (a car the segmenter split in two; a detached mirror is inside the box anyway, a mark's plate or a caption's band is far smaller) */
  keepShare: 0.25,
  /** room below the wheels and at the sides for the shadow, as shares of the car's width */
  ground: 0.055, side: 0.04,
  /** the shadow's darkness: the wide soft one and the contact one at the tyres */
  softAlpha: 0.5, contactAlpha: 0.78
} as const;

type Box = { x0: number; y0: number; x1: number; y1: number };

/** The pieces of the subject on a grid of cells: the car (the largest) and what is kept with it. Pure. */
export function subjectCells(img: Rgba, cell: number = FRAME.cell, solid: number = FRAME.solid): { gw: number; gh: number; keep: Uint8Array; car: Box; dropped: number } | null {
  const { width: W, height: H, data } = img;
  const gw = Math.ceil(W / cell), gh = Math.ceil(H / cell);
  const on = new Uint8Array(gw * gh);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) if (data[(y * W + x) * 4 + 3]! >= solid) on[Math.floor(y / cell) * gw + Math.floor(x / cell)] = 1;
  const label = new Int32Array(gw * gh).fill(-1);
  const pieces: Array<{ n: number } & Box> = [];
  const stack: number[] = [];
  for (let i = 0; i < on.length; i++) {
    if (!on[i] || label[i]! >= 0) continue;
    const id = pieces.length, p = { n: 0, x0: gw, y0: gh, x1: -1, y1: -1 };
    label[i] = id; stack.push(i);
    while (stack.length) {
      const k = stack.pop()!, x = k % gw, y = (k - x) / gw;
      p.n++; if (x < p.x0) p.x0 = x; if (x > p.x1) p.x1 = x; if (y < p.y0) p.y0 = y; if (y > p.y1) p.y1 = y;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const nx = x + dx, ny = y + dy;
        if ((dx || dy) && nx >= 0 && ny >= 0 && nx < gw && ny < gh) { const q = ny * gw + nx; if (on[q] && label[q]! < 0) { label[q] = id; stack.push(q); } }
      }
    }
    pieces.push(p);
  }
  if (!pieces.length) return null;
  const big = pieces.reduce((a, b) => (b.n > a.n ? b : a));
  const keepIds = new Set<number>();
  const car: Box = { x0: big.x0, y0: big.y0, x1: big.x1, y1: big.y1 };
  pieces.forEach((p, id) => {
    const within = p.x0 >= big.x0 && p.x1 <= big.x1 && p.y0 >= big.y0 && p.y1 <= big.y1;
    if (p === big || within || p.n >= big.n * FRAME.keepShare) {
      keepIds.add(id);
      car.x0 = Math.min(car.x0, p.x0); car.y0 = Math.min(car.y0, p.y0); car.x1 = Math.max(car.x1, p.x1); car.y1 = Math.max(car.y1, p.y1);
    }
  });
  const keep = new Uint8Array(gw * gh);
  for (let i = 0; i < keep.length; i++) if (label[i]! >= 0 && keepIds.has(label[i]!)) keep[i] = 1;
  return { gw, gh, keep, car, dropped: pieces.length - keepIds.size };
}

/** The cut-out framed for the studio: marks and captions made clear, the car cropped to its edges, the contact shadow under it. */
export function frameRgba(img: Rgba): Omit<Framed, 'png'> & { image: Rgba } | null {
  const { width: W, height: H, data } = img, c = FRAME.cell;
  // r31: the subject at a firm alpha, then at firmer ones while the car keeps most of its cells (what falls away is the
  // haze, the floor's reflection and the soft shadow, never the car's own solid body), or while it is still the whole
  // frame (the haze holds it all together)
  let cells = subjectCells(img, c, FRAME.solid), solid: number = FRAME.solid;
  // what is drawn: the pieces at the first alpha that is not haze (so a window the segmenter left half clear stays
  // drawn inside the crop, even when the crop is found at a firmer alpha)
  let draw = cells;
  const count = (k: { keep: Uint8Array }) => k.keep.reduce((n, v) => n + v, 0);
  const haze = (k: { car: Box }) => ((k.car.x1 - k.car.x0 + 1) * c) / W >= FRAME.hazeShare && ((k.car.y1 - k.car.y0 + 1) * c) / H >= FRAME.hazeShare;
  for (const t of FRAME.firmer) {
    if (!cells) break;
    const k = subjectCells(img, c, t);
    if (!k || (!haze(cells) && count(k) < count(cells) * FRAME.firmKeeps)) break;
    if (haze(cells)) draw = k;
    cells = k; solid = t;
  }
  if (!cells || !draw) return null;
  // the car's soft edge (below the firm alpha) is kept: the drawn cells grown by one
  const kept = new Uint8Array(draw.keep.length);
  for (let i = 0; i < kept.length; i++) {
    if (!draw.keep[i]) continue;
    const gx = i % draw.gw, gy = (i - gx) / draw.gw;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const nx = gx + dx, ny = gy + dy; if (nx >= 0 && ny >= 0 && nx < draw.gw && ny < draw.gh) kept[ny * draw.gw + nx] = 1; }
  }
  const isCar = (x: number, y: number) => !!cells!.keep[Math.floor(y / c) * cells!.gw + Math.floor(x / c)] && data[(y * W + x) * 4 + 3]! >= solid;
  // the car's pixel edges inside its cells (firm pixels only), as counts per row and column
  const bx0 = cells.car.x0 * c, bx1 = Math.min(W, (cells.car.x1 + 1) * c), by0 = cells.car.y0 * c, by1 = Math.min(H, (cells.car.y1 + 1) * c);
  const cols = new Uint32Array(bx1 - bx0), rows = new Uint32Array(by1 - by0);
  for (let y = by0; y < by1; y++) for (let x = bx0; x < bx1; x++) if (isCar(x, y)) { cols[x - bx0]!++; rows[y - by0]!++; }
  const edges = (a: Uint32Array) => {
    let max = 0; for (const v of a) if (v > max) max = v;
    const min = Math.max(1, Math.ceil(max * FRAME.trim));
    let lo = 0, hi = a.length - 1;
    while (lo <= hi && a[lo]! < min) lo++;
    while (hi >= lo && a[hi]! < min) hi--;
    return [lo, hi] as const;
  };
  const [cx0, cx1] = edges(cols), [ry0, ry1] = edges(rows);
  if (cx1 < cx0 || ry1 < ry0) return null;
  const x0 = bx0 + cx0, x1 = bx0 + cx1, y0 = by0 + ry0, y1 = by0 + ry1;
  const bw = x1 - x0 + 1, bh = y1 - y0 + 1;
  if (bw < 24 || bh < 16) return null;
  const padB = Math.max(4, Math.round(bw * FRAME.ground)), padS = Math.max(2, Math.round(bw * FRAME.side));
  const OW = bw + 2 * padS, OH = bh + padB;
  const out = new Uint8ClampedArray(OW * OH * 4);
  // the footprint: where the car touches the ground, from the lowest rows of the car
  const band = Math.max(2, Math.round(bh * 0.12));
  let fl = bw, fr = -1;
  for (let y = y1 - band + 1; y <= y1; y++) for (let x = x0; x <= x1; x++) if (isCar(x, y)) { if (x - x0 < fl) fl = x - x0; if (x - x0 > fr) fr = x - x0; }
  if (fr < fl) { fl = 0; fr = bw - 1; }
  const cx = padS + (fl + fr) / 2, gy = bh - 1;                // the wheel line, in the output
  const rxSoft = ((fr - fl) / 2) * 1.06 + padS * 0.5, rySoft = padB * 0.95 + bh * 0.03;
  const rxCore = ((fr - fl) / 2) * 0.97, ryCore = Math.max(2, padB * 0.32);
  for (let y = Math.max(0, Math.floor(gy - rySoft)); y < OH; y++) {
    for (let x = 0; x < OW; x++) {
      const ds = ((x - cx) / rxSoft) ** 2 + ((y - gy) / rySoft) ** 2, dc = ((x - cx) / rxCore) ** 2 + ((y - gy) / ryCore) ** 2;
      const a1 = ds < 1 ? FRAME.softAlpha * (1 - ds) ** 2 : 0, a2 = dc < 1 ? FRAME.contactAlpha * (1 - dc) ** 1.5 : 0;
      const a = 1 - (1 - a1) * (1 - a2);
      if (a > 0.004) out[(y * OW + x) * 4 + 3] = Math.round(a * 255);
    }
  }
  // the car over its shadow (dropped pieces clear)
  for (let y = 0; y < bh; y++) for (let x = 0; x < bw; x++) {
    const sx = x0 + x, sy = y0 + y, si = (sy * W + sx) * 4;
    if (!kept[Math.floor(sy / c) * cells.gw + Math.floor(sx / c)]) continue;
    const ca = data[si + 3]! / 255;
    if (ca <= 0) continue;
    const oi = ((y) * OW + x + padS) * 4, sa = out[oi + 3]! / 255;
    const a = ca + sa * (1 - ca);
    // the shadow is black: the colour is the car's, darkened where the shadow shows through its soft edge
    const k = a > 0 ? ca / a : 0;
    out[oi] = Math.round(data[si]! * k); out[oi + 1] = Math.round(data[si + 1]! * k); out[oi + 2] = Math.round(data[si + 2]! * k);
    out[oi + 3] = Math.round(a * 255);
  }
  const image = { width: OW, height: OH, data: out };
  return { image, width: OW, height: OH, ground: (padB) / OH, side: padS / OW, dropped: cells.dropped, share: { w: bw / W, h: bh / H }, stats: statsOf(image, 200) };
}

/** The whole step on the segmenter's PNG; null when the PNG cannot be read or holds no subject (the worker then frames
 *  the cut-out as before). */
export async function frameSubject(png: Uint8Array): Promise<Framed | null> {
  const img = await decodePng(png);
  if (!img) return null;
  const f = frameRgba(img);
  if (!f) return null;
  const { image, ...rest } = f;
  return { ...rest, png: await encodePng(image) };
}

/** Where the framed car goes in a studio frame of W x H: about 80% of the width (less for a front or rear view, which is
 *  held by the height), its wheels on the floor line 26% above the bottom, centred. Pure; the compositor draws with it. */
export const STUDIO = { carWidth: 0.8, carHeight: 0.66, floor: 0.26 } as const;
export function placeSubject(f: { width: number; height: number; ground: number; side: number }, W: number, H: number) {
  const aspect = f.width / f.height;
  const carAspect = (f.width * (1 - 2 * f.side)) / (f.height * (1 - f.ground));
  // the car itself at most carWidth of the frame wide and carHeight high
  const carW = Math.min(W * STUDIO.carWidth, H * STUDIO.carHeight * carAspect);
  const width = Math.round(carW / (1 - 2 * f.side)), height = Math.round(width / aspect);
  const bottom = Math.max(0, Math.round(H * STUDIO.floor - height * f.ground));
  return { width, height, left: Math.round((W - width) / 2), bottom, carShare: carW / W };
}
