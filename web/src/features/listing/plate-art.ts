// The CARMA plate (r35 S2, owner, Nov 9): the company's own Ontario personalized plate, drawn in the current Ontario design
// (white, blue lettering, "ONTARIO" at the top, "Yours to discover" at the bottom), on every listing photo's rear plate and on
// the sample cars. Drawn from the letters' outlines (presets/plate-glyphs.json, scripts/gen-plate-glyphs.py), so it needs no
// font: as SVG paths (the sample cars, public/plates/carma-ontario.svg) and as pixels (the photos, plate-photo.ts).
// 12 x 6 inches: drawn on a 600 x 300 board. Pure.
import glyphData from './presets/plate-glyphs.json' with { type: 'json' };
import { fillPolys } from './raster.ts';
import type { Rgba } from './subject-frame.ts';

export const PLATE_TEXT = 'CARMA';
export const PLATE = { width: 600, height: 300, radius: 22 } as const;
/** Ontario's plate blue, and the white of the plate. */
export const PLATE_BLUE: [number, number, number] = [18, 58, 140];
export const PLATE_WHITE: [number, number, number] = [246, 247, 245];

type Font = { unitsPerEm: number; capHeight: number; glyphs: Record<string, { advance: number; contours: number[][][] }> };
const F = glyphData as unknown as { plate: Font; small: Font };

/** A line of text as polygons on the 600 x 300 board: centred on x, its capitals `cap` high on `baseline`, squeezed by `sx`. */
function line(font: Font, text: string, baseline: number, cap: number, sx = 1, maxWidth = 560): number[][] {
  const s0 = cap / font.capHeight;
  const adv = [...text].reduce((a, ch) => a + (font.glyphs[ch]?.advance ?? font.unitsPerEm * 0.3), 0);
  const kx = Math.min(sx * s0, maxWidth / adv), ky = s0;
  let pen = (PLATE.width - adv * kx) / 2;
  const out: number[][] = [];
  for (const ch of text) {
    const g = font.glyphs[ch];
    if (g) for (const c of g.contours) out.push(c.flatMap(([x, y]) => [pen + x! * kx, baseline - y! * ky]));
    pen += (g?.advance ?? font.unitsPerEm * 0.3) * kx;
  }
  return out;
}

/** The plate's shapes: the board's rounded outline, and each line of blue lettering. */
export function plateShapes(text = PLATE_TEXT) {
  const r = PLATE.radius, W = PLATE.width, H = PLATE.height, board: number[] = [];
  const arc = (cx: number, cy: number, a0: number) => { for (let i = 0; i <= 6; i++) { const a = a0 + (i / 6) * (Math.PI / 2); board.push(cx + r * Math.cos(a), cy + r * Math.sin(a)); } };
  arc(W - r, r, -Math.PI / 2); arc(W - r, H - r, 0); arc(r, H - r, Math.PI / 2); arc(r, r, Math.PI);
  return {
    board,
    top: line(F.small, 'ONTARIO', 52, 30, 1.15, 300),
    main: line(F.plate, text.toUpperCase().slice(0, 8), 228, 148, 0.86, 540),
    bottom: line(F.small, 'Yours to discover', 278, 24, 1, 320)
  };
}

const d = (polys: number[][]) => polys.map((p) => { const pts: string[] = []; for (let i = 0; i + 1 < p.length; i += 2) pts.push(`${p[i]!.toFixed(1)},${p[i + 1]!.toFixed(1)}`); return `M${pts.join('L')}Z`; }).join('');
const rgb = (c: number[]) => `rgb(${c.join(',')})`;

/** The plate as SVG content on the 600 x 300 board (no <svg> wrapper): for the sample cars and the asset file. */
export function plateSvgInner(text = PLATE_TEXT): string {
  const s = plateShapes(text);
  return `<path d="${d([s.board])}" fill="${rgb(PLATE_WHITE)}" stroke="#c9ccd2" stroke-width="3"/>`
    + `<path d="${d(s.main)}" fill="#0b2a66" opacity=".35" transform="translate(2 3)" fill-rule="evenodd"/>`
    + `<g fill="${rgb(PLATE_BLUE)}" fill-rule="evenodd"><path d="${d(s.top)}"/><path d="${d(s.main)}"/><path d="${d(s.bottom)}"/></g>`;
}
export function plateSvg(text = PLATE_TEXT): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${PLATE.width} ${PLATE.height}" width="${PLATE.width}" height="${PLATE.height}">${plateSvgInner(text)}</svg>`;
}

const cache = new Map<string, Rgba>();
/** The plate as pixels, `w` wide (2:1), antialiased, its corners clear: drawn once per size. */
export function plateRgba(w: number, text = PLATE_TEXT): Rgba {
  const W = Math.max(40, Math.round(w)), H = Math.round(W / 2), key = `${text}:${W}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const k = W / PLATE.width, s = plateShapes(text);
  const scale = (polys: number[][]) => polys.map((p) => p.map((v) => v * k));
  const board = fillPolys(scale([s.board]), W, H);
  const ink = fillPolys(scale([...s.top, ...s.main, ...s.bottom]), W, H);
  const shade = fillPolys(scale(s.main).map((p) => p.map((v, i) => v + (i % 2 ? 3 * k : 2 * k))), W, H);
  const data = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const i = y * W + x, o = i * 4, a = board[i]!;
    // the white of the plate with a faint top-to-bottom sheen, the embossed letters' shadow, the blue
    const sheen = 1 - 0.035 * (y / H);
    let r = PLATE_WHITE[0] * sheen, g = PLATE_WHITE[1] * sheen, b = PLATE_WHITE[2] * sheen;
    const sh = shade[i]! * 0.3;
    r = r * (1 - sh) + 11 * sh; g = g * (1 - sh) + 42 * sh; b = b * (1 - sh) + 102 * sh;
    const t = ink[i]!;
    r = r * (1 - t) + PLATE_BLUE[0] * t; g = g * (1 - t) + PLATE_BLUE[1] * t; b = b * (1 - t) + PLATE_BLUE[2] * t;
    // the rim
    const edge = Math.min(x, y, W - 1 - x, H - 1 - y);
    if (edge < 1.5 * k + 1) { r *= 0.86; g *= 0.87; b *= 0.89; }
    data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = Math.round(a * 255);
  }
  const out = { width: W, height: H, data };
  cache.set(key, out);
  if (cache.size > 16) cache.delete(cache.keys().next().value!);
  return out;
}
