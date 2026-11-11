// The flyer cover of a listing (release 36, migration 2100): the car's cover photo with a flyer band drawn on it, like a
// printed dealer flyer: the logo and a badge at the top, a dark band at the bottom with the headline (the car), the offer
// (the live price a day) in the accent colour, and the call to action in an accent pill. Every word and colour comes from
// Program settings listing_cover_flyer, filled for the car by the database (app.cover_flyer_spec): nothing is written
// here. Drawn without a canvas (Inter Display ExtraBold outlines, presets/flyer-glyphs.json; the logo's paths), pure, so the
// worker and the unit test share it.
import glyphData from './presets/flyer-glyphs.json' with { type: 'json' };
import logoData from './presets/showroom-logo.json' with { type: 'json' };
import { fillPolys } from './raster.ts';
import type { Rgba } from './subject-frame.ts';

export interface FlyerSpec { headline?: string | null; offer?: string | null; cta?: string | null; badge?: string | null; logo?: boolean | null;
  band?: string | null; accent?: string | null; text?: string | null }

type Glyphs = { unitsPerEm: number; glyphs: Record<string, { advance: number; contours: number[][][] }> };
const G = glyphData as unknown as Glyphs;
type Logo = { viewBox: number[]; paths: Array<{ fill: number[]; polys: number[][] }> };
const L = logoData as unknown as Logo;
const CAP = 0.727; // Inter's cap height a unit of size

/** The words as the flyer letters them: capitals, the signs it has; anything else a space; spaces collapsed. */
export function flyerText(s: string | null | undefined): string {
  return [...(s ?? '').toUpperCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')].map((c) => (G.glyphs[c] ? c : ' ')).join('').replace(/\s+/g, ' ').trim();
}
/** #RRGGBB to [r, g, b]; a bad value is the fallback. */
export function hex(c: string | null | undefined, fb: [number, number, number]): [number, number, number] {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(c ?? '');
  return m ? [parseInt(m[1]!, 16), parseInt(m[2]!, 16), parseInt(m[3]!, 16)] : fb;
}
/** The width of a line of text at a cap height. */
export function textWidth(text: string, cap: number): number {
  const size = cap / CAP;
  return [...text].reduce((a, ch) => a + (G.glyphs[ch] ?? G.glyphs[' ']!).advance, 0) * (size / G.unitsPerEm);
}
/** The largest cap height (at most `cap`) at which the text fits `max` pixels. */
export function fitCap(text: string, cap: number, max: number): number {
  const w = textWidth(text, cap);
  return w <= max ? cap : Math.max(8, Math.floor(cap * (max / w)));
}
function textPolys(text: string, x: number, top: number, cap: number): number[][] {
  const size = cap / CAP, s = size / G.unitsPerEm, base = top + cap;
  let pen = x; const out: number[][] = [];
  for (const ch of text) {
    const g = G.glyphs[ch] ?? G.glyphs[' ']!;
    for (const c of g.contours) out.push(c.flatMap(([gx, gy]) => [pen + gx! * s, base - gy! * s]));
    pen += g.advance * s;
  }
  return out;
}

/** Paints polygons in a colour, with their coverage as alpha, only over their own box (no full-frame mask). */
function paint(img: Rgba, polys: number[][], rgb: [number, number, number], alpha = 1): void {
  if (!polys.length) return;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const p of polys) for (let i = 0; i < p.length; i += 2) { x0 = Math.min(x0, p[i]!); x1 = Math.max(x1, p[i]!); y0 = Math.min(y0, p[i + 1]!); y1 = Math.max(y1, p[i + 1]!); }
  x0 = Math.max(0, Math.floor(x0)); y0 = Math.max(0, Math.floor(y0)); x1 = Math.min(img.width, Math.ceil(x1) + 1); y1 = Math.min(img.height, Math.ceil(y1) + 1);
  const w = x1 - x0, h = y1 - y0;
  if (w <= 0 || h <= 0) return;
  const m = fillPolys(polys.map((p) => p.map((v, i) => (i % 2 === 0 ? v - x0 : v - y0))), w, h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const a = m[y * w + x]! * alpha; if (a <= 0) continue;
    const i = ((y + y0) * img.width + (x + x0)) * 4;
    img.data[i] = img.data[i]! + (rgb[0] - img.data[i]!) * a;
    img.data[i + 1] = img.data[i + 1]! + (rgb[1] - img.data[i + 1]!) * a;
    img.data[i + 2] = img.data[i + 2]! + (rgb[2] - img.data[i + 2]!) * a;
  }
}
const rect = (x: number, y: number, w: number, h: number) => [x, y, x + w, y, x + w, y + h, x, y + h];
/** A rounded rectangle as one polygon (8 points a corner). */
function pill(x: number, y: number, w: number, h: number, r: number): number[] {
  const out: number[] = [];
  const corner = (cx: number, cy: number, a0: number) => { for (let k = 0; k <= 8; k++) { const a = a0 + (k / 8) * (Math.PI / 2); out.push(cx + r * Math.cos(a), cy + r * Math.sin(a)); } };
  corner(x + w - r, y + r, -Math.PI / 2); corner(x + w - r, y + h - r, 0); corner(x + r, y + h - r, Math.PI / 2); corner(x + r, y + r, Math.PI);
  return out;
}

/** The layout on a frame W x H (the site's 1800 x 1200): where each part goes. Exported for the test. */
export function flyerLayout(W: number, H: number) {
  const u = W / 1800;
  return { band: { y: Math.round(H - 270 * u), h: Math.round(270 * u) }, pad: Math.round(64 * u), headCap: Math.round(62 * u), offerCap: Math.round(46 * u),
    ctaCap: Math.round(34 * u), ctaPad: Math.round(30 * u), ctaH: Math.round(96 * u), logoW: Math.round(360 * u), badgeCap: Math.round(30 * u), badgeH: Math.round(76 * u) };
}

/** Draws the flyer on a copy of the photo. */
export function drawFlyer(photo: Rgba, spec: FlyerSpec): Rgba {
  const img: Rgba = { width: photo.width, height: photo.height, data: new Uint8ClampedArray(photo.data) };
  const W = img.width, H = img.height, k = flyerLayout(W, H);
  const band = hex(spec.band, [11, 11, 12]), accent = hex(spec.accent, [225, 6, 0]), ink = hex(spec.text, [255, 255, 255]);
  // the band: a soft fade into it, then solid
  const fade = Math.round(k.band.h * 0.45);
  for (let y = k.band.y - fade; y < H; y++) {
    if (y < 0) continue;
    const a = y < k.band.y ? 0.88 * ((y - (k.band.y - fade)) / fade) ** 1.6 : 0.88;
    for (let x = 0; x < W; x++) { const i = (y * W + x) * 4; for (let c = 0; c < 3; c++) img.data[i + c] = img.data[i + c]! + (band[c]! - img.data[i + c]!) * a; }
  }
  paint(img, [rect(0, k.band.y, W, Math.max(2, Math.round(6 * (W / 1800))))], accent);
  // the call to action: an accent pill on the right of the band
  const cta = flyerText(spec.cta);
  let right = W - k.pad;
  if (cta) {
    const cap = fitCap(cta, k.ctaCap, W * 0.36);
    const w = textWidth(cta, cap) + k.ctaPad * 2, y = k.band.y + (k.band.h - k.ctaH) / 2;
    paint(img, [pill(right - w, y, w, k.ctaH, k.ctaH / 2)], accent);
    paint(img, textPolys(cta, right - w + k.ctaPad, y + (k.ctaH - cap) / 2, cap), ink);
    right -= w + k.pad / 2;
  }
  // the headline and the offer on the left
  const head = flyerText(spec.headline), offer = flyerText(spec.offer);
  const room = right - k.pad;
  const hc = head ? fitCap(head, k.headCap, room) : 0, oc = offer ? fitCap(offer, k.offerCap, room) : 0;
  const gap = head && offer ? Math.round(k.offerCap * 0.7) : 0;
  let y = k.band.y + (k.band.h - (hc + gap + oc)) / 2;
  if (head) { paint(img, textPolys(head, k.pad, y, hc), ink); y += hc + gap; }
  if (offer) paint(img, textPolys(offer, k.pad, y, oc), accent);
  // the logo, top left, on a soft dark plate so it reads on any photo
  if (spec.logo !== false) {
    const [vx, vy, vw, vh] = L.viewBox as [number, number, number, number];
    const s = k.logoW / vw, ox = k.pad, oy = k.pad * 0.8, plateH = vh * s + k.pad * 0.6;
    paint(img, [pill(ox - k.pad * 0.4, oy - k.pad * 0.3, k.logoW + k.pad * 0.8, plateH, plateH / 2)], band, 0.55);
    for (const p of L.paths) {
      const polys = p.polys.map((poly) => poly.map((v, i) => (i % 2 === 0 ? ox + (v - vx) * s : oy + (v - vy) * s)));
      const isDark = (p.fill[0] ?? 0) + (p.fill[1] ?? 0) + (p.fill[2] ?? 0) < 120;
      paint(img, polys, isDark ? ink : [p.fill[0] ?? 255, p.fill[1] ?? 255, p.fill[2] ?? 255]);
    }
  }
  // the badge, top right
  const badge = flyerText(spec.badge);
  if (badge) {
    const cap = fitCap(badge, k.badgeCap, W * 0.4), w = textWidth(badge, cap) + k.ctaPad * 2, x = W - k.pad - w, by = k.pad * 0.8;
    paint(img, [pill(x, by, w, k.badgeH, k.badgeH / 2)], accent);
    paint(img, textPolys(badge, x + k.ctaPad, by + (k.badgeH - cap) / 2, cap), ink);
  }
  return img;
}
