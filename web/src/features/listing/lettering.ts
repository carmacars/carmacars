// The model's name in large outlined letters behind the car, as on every sample car image (studio.ts: Inter 800,
// 360 px, stretched to 1620 px across an 1800 x 1200 frame, a 2 px white outline at 13%, its baseline 240 px above
// the floor line at 888 px). For real photos the listing worker draws it into a transparent PNG band, placed by
// Cloudflare's draw between the studio backdrop and the car (cloudflare.ts composite). Pure: the glyphs come from
// presets/ghost-glyphs.json (scripts/gen-ghost-glyphs.py), the PNG is written here, deflate by CompressionStream.
import glyphData from './presets/ghost-glyphs.json' with { type: 'json' };
import { studioName } from '../car/studio.ts';

type Glyphs = { unitsPerEm: number; glyphs: Record<string, { advance: number; contours: number[][][] }> };
const G = glyphData as unknown as Glyphs;

/** Where the band sits on the 1800 x 1200 photo: its top edge and its size. */
export const LETTERING = { width: 1800, height: 360, top: 348, frameWidth: 1800, frameHeight: 1200 } as const;
const BASELINE = 648 - LETTERING.top;   // floor line 888 minus 20% of the height
const FONT_SIZE = 360;
const TEXT_LENGTH = 1620;
const STROKE = 2;
const ALPHA = 0.13;

/** The file name of a model's band in the public bucket (one per model name and version of the drawing). */
export const letteringPath = (name: string) => `site/backdrop/lettering-v1-${studioName(name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'car'}.png`;

/** The coverage mask of the outlined name (0 to 1 per pixel), LETTERING.width x LETTERING.height. */
export function letteringMask(name: string): Float32Array {
  const W = LETTERING.width, H = LETTERING.height;
  const mask = new Float32Array(W * H);
  const text = studioName(name);
  if (!text) return mask;
  const s = FONT_SIZE / G.unitsPerEm;
  const total = [...text].reduce((a, ch) => a + (G.glyphs[ch]?.advance ?? G.glyphs[' ']!.advance), 0) * s;
  const sx = TEXT_LENGTH / total;                     // lengthAdjust="spacingAndGlyphs": glyphs stretched to the length
  let pen = (W - TEXT_LENGTH) / 2;
  const r = STROKE / 2 + 0.5;
  const splat = (x: number, y: number) => {
    const x0 = Math.max(0, Math.floor(x - r)), x1 = Math.min(W - 1, Math.ceil(x + r));
    const y0 = Math.max(0, Math.floor(y - r)), y1 = Math.min(H - 1, Math.ceil(y + r));
    for (let yy = y0; yy <= y1; yy++) for (let xx = x0; xx <= x1; xx++) {
      const d = Math.hypot(xx + 0.5 - x, yy + 0.5 - y);
      const c = Math.max(0, Math.min(1, STROKE / 2 + 0.5 - d));
      const i = yy * W + xx;
      if (c > mask[i]!) mask[i] = c;
    }
  };
  for (const ch of text) {
    const g = G.glyphs[ch] ?? G.glyphs[' ']!;
    for (const contour of g.contours) {
      const pts = contour.map(([x, y]) => [pen + x! * s * sx, BASELINE - y! * s] as const);
      for (let i = 0; i < pts.length; i++) {
        const [ax, ay] = pts[i]!; const [bx, by] = pts[(i + 1) % pts.length]!;
        const n = Math.max(1, Math.ceil(Math.hypot(bx - ax, by - ay) * 2));
        for (let k = 0; k <= n; k++) splat(ax + ((bx - ax) * k) / n, ay + ((by - ay) * k) / n);
      }
    }
    pen += g.advance * s * sx;
  }
  return mask;
}

const CRC = new Uint32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = (b: Uint8Array) => { let c = 0xffffffff; for (const x of b) c = CRC[(c ^ x) & 0xff]! ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length); const v = new DataView(out.buffer);
  v.setUint32(0, data.length); for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8); v.setUint32(8 + data.length, crc(out.subarray(4, 8 + data.length)));
  return out;
}
async function zlib(raw: Uint8Array): Promise<Uint8Array> {
  const cs = new CompressionStream('deflate');
  const buf = await new Response(new Blob([raw as BlobPart]).stream().pipeThrough(cs)).arrayBuffer();
  return new Uint8Array(buf);
}

/** The band as a PNG: white, transparent except the outline at 13%. */
export async function letteringPng(name: string): Promise<Uint8Array> {
  const W = LETTERING.width, H = LETTERING.height;
  const m = letteringMask(name);
  const row = W * 4 + 1;
  const raw = new Uint8Array(row * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const a = m[y * W + x]!;
    if (!a) continue;
    const o = y * row + 1 + x * 4;
    raw[o] = 255; raw[o + 1] = 255; raw[o + 2] = 255; raw[o + 3] = Math.round(255 * ALPHA * a);
  }
  const ihdr = new Uint8Array(13); const v = new DataView(ihdr.buffer);
  v.setUint32(0, W); v.setUint32(4, H); ihdr[8] = 8; ihdr[9] = 6;
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', await zlib(raw)), chunk('IEND', new Uint8Array(0))];
  const out = new Uint8Array(parts.reduce((a, p) => a + p.length, 0)); let k = 0;
  for (const p of parts) { out.set(p, k); k += p.length; }
  return out;
}
