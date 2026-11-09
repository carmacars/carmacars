// The plates of a listing photo (r35 S2, owner, Nov 9), replacing the plate box cover: the front plate is edited out (the
// bumper filled in, no box, no visible blur patch) and the rear plate becomes the company's own CARMA Ontario plate
// (plate-art.ts), warped in perspective onto the plate's corners and matched to the photo's light, white balance,
// sharpness and grain, with a faint reflection, so it looks photographed, not pasted. Pure pixel work on RGBA (no canvas):
// the same code runs in the browser's plate editor and in the worker (the redo of every covered photo). The image model,
// when it may be asked, edits the front plate out first (worker.ts); this is its fallback.
import type { Rgba } from './subject-frame.ts';
import { plateRgba } from './plate-art.ts';

export type Pt = [number, number];
/** A plate's corners on the photo, in pixels: top left, top right, bottom right, bottom left. */
export type Quad = [Pt, Pt, Pt, Pt];
export interface PxBox { x: number; y: number; w: number; h: number }
export type PlateEnd = 'front' | 'rear';

/** The end a plate is on from the photo's shot (front, front_left... or rear, rear_left...); a side shot's plate: rear. */
export const plateEnd = (shot: string | null | undefined): PlateEnd => (/front/.test(shot ?? '') ? 'front' : 'rear');

// ================================================================ the perspective map
/** The 3 x 3 map (row major, h33 = 1) taking the four `from` corners to the four `to` corners. null when degenerate. */
export function homography(from: Quad, to: Quad): number[] | null {
  const A: number[][] = [], b: number[] = [];
  for (let i = 0; i < 4; i++) {
    const [x, y] = from[i]!, [u, v] = to[i]!;
    A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.push(u);
    A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); b.push(v);
  }
  // Gaussian elimination with partial pivoting
  for (let c = 0; c < 8; c++) {
    let p = c;
    for (let r = c + 1; r < 8; r++) if (Math.abs(A[r]![c]!) > Math.abs(A[p]![c]!)) p = r;
    if (Math.abs(A[p]![c]!) < 1e-10) return null;
    [A[c], A[p]] = [A[p]!, A[c]!]; [b[c], b[p]] = [b[p]!, b[c]!];
    for (let r = 0; r < 8; r++) {
      if (r === c) continue;
      const f = A[r]![c]! / A[c]![c]!;
      if (!f) continue;
      for (let k = c; k < 8; k++) A[r]![k]! -= f * A[c]![k]!;
      b[r]! -= f * b[c]!;
    }
  }
  return [...b.map((v, i) => v / A[i]![i]!), 1];
}
export const mapPt = (H: number[], [x, y]: Pt): Pt => { const w = H[6]! * x + H[7]! * y + H[8]!; return [(H[0]! * x + H[1]! * y + H[2]!) / w, (H[3]! * x + H[4]! * y + H[5]!) / w]; };
export const boxQuad = (b: PxBox): Quad => [[b.x, b.y], [b.x + b.w, b.y], [b.x + b.w, b.y + b.h], [b.x, b.y + b.h]];

const lumAt = (img: Rgba, x: number, y: number) => {
  const xx = Math.max(0, Math.min(img.width - 1, Math.round(x))), yy = Math.max(0, Math.min(img.height - 1, Math.round(y))), i = (yy * img.width + xx) * 4;
  return 0.299 * img.data[i]! + 0.587 * img.data[i + 1]! + 0.114 * img.data[i + 2]!;
};

/** The plate's corners found from its box: the strongest edges near each side of the box, in its upper and lower half
 *  (left, right) and its left and right half (top, bottom), so a plate seen at an angle gets its real slant. The box's own
 *  corners when the edges do not make a sensible plate. */
export function plateQuad(img: Rgba, b: PxBox): Quad {
  const fallback = boxQuad(b);
  if (b.w < 12 || b.h < 6) return fallback;
  // the plate's outline is the outermost strong edge on each side (its characters make strong edges inside it)
  const pick = (scores: Array<[number, number]>, outward: 1 | -1) => {
    const max = Math.max(...scores.map((s) => s[1]));
    const strong = scores.filter((s) => s[1] >= max * 0.6).map((s) => s[0]);
    return strong.length ? (outward > 0 ? Math.max(...strong) : Math.min(...strong)) : scores[Math.floor(scores.length / 2)]![0];
  };
  const vEdge = (x0: number, x1: number, y0: number, y1: number, outward: 1 | -1) => {
    const sc: Array<[number, number]> = [];
    for (let x = Math.max(1, Math.floor(x0)); x <= Math.min(img.width - 2, Math.ceil(x1)); x++) {
      let s = 0; for (let y = Math.floor(y0); y < y1; y++) s += Math.abs(lumAt(img, x + 1, y) - lumAt(img, x - 1, y));
      sc.push([x, s]);
    }
    return pick(sc, outward);
  };
  const hEdge = (y0: number, y1: number, x0: number, x1: number, outward: 1 | -1) => {
    const sc: Array<[number, number]> = [];
    for (let y = Math.max(1, Math.floor(y0)); y <= Math.min(img.height - 2, Math.ceil(y1)); y++) {
      let s = 0; for (let x = Math.floor(x0); x < x1; x++) s += Math.abs(lumAt(img, x, y + 1) - lumAt(img, x, y - 1));
      sc.push([y, s]);
    }
    return pick(sc, outward);
  };
  const mx = b.w * 0.18, my = b.h * 0.25;
  // each side as a line through two points measured near its ends (20% and 80% along it), the corners where lines meet
  const ya = b.y + b.h * 0.2, yb = b.y + b.h * 0.8, xa = b.x + b.w * 0.2, xb = b.x + b.w * 0.8, sy = b.h * 0.12, sx = b.w * 0.1;
  const L: [Pt, Pt] = [[vEdge(b.x - mx, b.x + mx, ya - sy, ya + sy, -1), ya], [vEdge(b.x - mx, b.x + mx, yb - sy, yb + sy, -1), yb]];
  const R: [Pt, Pt] = [[vEdge(b.x + b.w - mx, b.x + b.w + mx, ya - sy, ya + sy, 1), ya], [vEdge(b.x + b.w - mx, b.x + b.w + mx, yb - sy, yb + sy, 1), yb]];
  const T: [Pt, Pt] = [[xa, hEdge(b.y - my, b.y + my, xa - sx, xa + sx, -1)], [xb, hEdge(b.y - my, b.y + my, xb - sx, xb + sx, -1)]];
  const B: [Pt, Pt] = [[xa, hEdge(b.y + b.h - my, b.y + b.h + my, xa - sx, xa + sx, 1)], [xb, hEdge(b.y + b.h - my, b.y + b.h + my, xb - sx, xb + sx, 1)]];
  const meet = ([p1, p2]: [Pt, Pt], [p3, p4]: [Pt, Pt]): Pt => {
    const d = (p1[0] - p2[0]) * (p3[1] - p4[1]) - (p1[1] - p2[1]) * (p3[0] - p4[0]);
    if (Math.abs(d) < 1e-9) return p1;
    const a = p1[0] * p2[1] - p1[1] * p2[0], c = p3[0] * p4[1] - p3[1] * p4[0];
    return [(a * (p3[0] - p4[0]) - (p1[0] - p2[0]) * c) / d, (a * (p3[1] - p4[1]) - (p1[1] - p2[1]) * c) / d];
  };
  const q: Quad = [meet(L, T), meet(R, T), meet(R, B), meet(L, B)];
  const lT = q[0][0], lB = q[3][0], rT = q[1][0], rB = q[2][0];
  // sane: convex, about the box's size, sides roughly parallel
  const area = (p: Quad) => Math.abs(p.reduce((s, [x, y], i) => { const [x2, y2] = p[(i + 1) % 4]!; return s + x * y2 - x2 * y; }, 0)) / 2;
  const cross = (o: Pt, a: Pt, c: Pt) => (a[0] - o[0]) * (c[1] - o[1]) - (a[1] - o[1]) * (c[0] - o[0]);
  const convex = [0, 1, 2, 3].every((i) => cross(q[i]!, q[(i + 1) % 4]!, q[(i + 2) % 4]!) > 0);
  const ratio = area(q) / (b.w * b.h);
  if (!convex || ratio < 0.6 || ratio > 1.45 || Math.abs((rT - lT) - (rB - lB)) > b.w * 0.35) return fallback;
  return q;
}

// ================================================================ the photo's look around the plate
export interface Look { light: number; wb: [number, number, number]; grain: number; soft: number }
/** The light, white balance, grain and softness of the photo around a plate (a ring around its box). */
export function lookAround(img: Rgba, b: PxBox): Look {
  const x0 = Math.max(0, Math.floor(b.x - b.w * 0.35)), x1 = Math.min(img.width, Math.ceil(b.x + b.w * 1.35));
  const y0 = Math.max(0, Math.floor(b.y - b.h * 0.6)), y1 = Math.min(img.height, Math.ceil(b.y + b.h * 1.6));
  const lums: number[] = [], bright: number[][] = []; let res = 0, rn = 0, lap = 0;
  for (let y = y0 + 1; y < y1 - 1; y += 2) for (let x = x0 + 1; x < x1 - 1; x += 2) {
    if (x >= b.x && x < b.x + b.w && y >= b.y && y < b.y + b.h) continue;
    const i = (y * img.width + x) * 4, l = lumAt(img, x, y);
    lums.push(l); bright.push([img.data[i]!, img.data[i + 1]!, img.data[i + 2]!, l]);
    const m = (lumAt(img, x - 1, y) + lumAt(img, x + 1, y) + lumAt(img, x, y - 1) + lumAt(img, x, y + 1)) / 4;
    res += (l - m) ** 2; rn++; lap += Math.abs(l - m);
  }
  if (lums.length < 8) return { light: 1, wb: [1, 1, 1], grain: 2, soft: 0 };
  lums.sort((a, c) => a - c);
  const p90 = lums[Math.floor(lums.length * 0.9)]!;
  bright.sort((a, c) => c[3]! - a[3]!);
  const top = bright.slice(0, Math.max(4, Math.floor(bright.length * 0.2)));
  const mean = [0, 1, 2].map((c) => top.reduce((s, p) => s + p[c]!, 0) / top.length);
  const ml = (mean[0]! + mean[1]! + mean[2]!) / 3 || 1;
  const wb = mean.map((v) => Math.max(0.85, Math.min(1.15, v / ml))) as [number, number, number];
  const sharp = lap / Math.max(1, rn);
  return { light: Math.max(0.42, Math.min(1.02, (p90 + 40) / 255)), wb, grain: Math.min(9, Math.sqrt(res / Math.max(1, rn)) * 0.6), soft: sharp < 2.5 ? 1 : sharp < 5 ? 0.5 : 0 };
}

const hash = (x: number, y: number) => { let h = Math.imul(x * 374761393 + y * 668265263, 1274126177); h ^= h >>> 15; return ((h >>> 0) % 1000) / 1000 - 0.5; };

// ================================================================ the rear plate: CARMA
/** The CARMA plate drawn onto `quad` (perspective), lit and coloured as the photo there, with its grain and a faint
 *  reflection, antialiased at its edges. In place. */
export function drawPlate(img: Rgba, quad: Quad, look: Look, text?: string): void {
  const xs = quad.map((p) => p[0]), ys = quad.map((p) => p[1]);
  const x0 = Math.max(0, Math.floor(Math.min(...xs)) - 1), x1 = Math.min(img.width, Math.ceil(Math.max(...xs)) + 1);
  const y0 = Math.max(0, Math.floor(Math.min(...ys)) - 1), y1 = Math.min(img.height, Math.ceil(Math.max(...ys)) + 1);
  const widthPx = Math.max(quad[1][0] - quad[0][0], quad[2][0] - quad[3][0], 20);
  const plate = plateRgba(Math.min(1200, Math.max(120, widthPx * 2)), text);
  const P = plate.width, Q = plate.height;
  const inv = homography(quad, [[0, 0], [P, 0], [P, Q], [0, Q]]);
  if (!inv) return;
  const out = new Float32Array((x1 - x0) * (y1 - y0) * 4);
  const SS = [[0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]];
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    let r = 0, g = 0, bl = 0, a = 0;
    for (const [sx, sy] of SS) {
      const [u, v] = mapPt(inv, [x + sx!, y + sy!]);
      if (u < 0 || v < 0 || u >= P - 1 || v >= Q - 1) continue;
      const ui = Math.floor(u), vi = Math.floor(v), fu = u - ui, fv = v - vi;
      for (let k = 0; k < 4; k++) {
        const xx = ui + (k & 1), yy = vi + (k >> 1), w = ((k & 1) ? fu : 1 - fu) * ((k >> 1) ? fv : 1 - fv), i = (yy * P + xx) * 4, al = (plate.data[i + 3]! / 255) * w;
        r += plate.data[i]! * al; g += plate.data[i + 1]! * al; bl += plate.data[i + 2]! * al; a += al;
      }
    }
    const o = ((y - y0) * (x1 - x0) + (x - x0)) * 4;
    if (a > 0) { out[o] = r / a; out[o + 1] = g / a; out[o + 2] = bl / a; }
    out[o + 3] = a / SS.length;
  }
  // the camera's softness: a light blur of the plate
  const bw = x1 - x0, bh = y1 - y0;
  if (look.soft > 0) {
    const copy = new Float32Array(out);
    for (let y = 1; y < bh - 1; y++) for (let x = 1; x < bw - 1; x++) for (let c = 0; c < 3; c++) {
      const o = (y * bw + x) * 4 + c;
      const m = (copy[o - 4]! + copy[o + 4]! + copy[o - bw * 4]! + copy[o + bw * 4]!) / 4;
      out[o] = copy[o]! * (1 - 0.5 * look.soft) + m * 0.5 * look.soft;
    }
  }
  const d = img.data, top = Math.min(...ys), hgt = Math.max(1, Math.max(...ys) - top);
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const o = ((y - y0) * bw + (x - x0)) * 4, a = out[o + 3]!;
    if (a <= 0.002) continue;
    // the light and white balance of the photo, a soft diagonal reflection across the top, the grain
    const refl = Math.max(0, 1 - Math.abs((x - x0) / bw - (y - top) / hgt * 0.6 - 0.25) * 4) * 0.07 * (1 - (y - top) / hgt);
    const n = hash(x, y) * look.grain * 2;
    const i = (y * img.width + x) * 4;
    for (let c = 0; c < 3; c++) {
      const v = out[o + c]! * look.light * look.wb[c]! + 255 * refl + n;
      d[i + c] = d[i + c]! + (Math.max(0, Math.min(255, v)) - d[i + c]!) * a;
    }
  }
}

// ================================================================ the front plate: edited out
/** The front plate edited out: the bumper filled in from all four sides (a Coons patch of the pixels around the plate,
 *  each side smoothed along its length), the photo's grain added back, feathered into the bumper so no edge shows. A
 *  busy surround (a grille, a sharp edge across the plate) is softened a little more, matched to the bumper. In place. */
export function removePlate(img: Rgba, b: PxBox, look?: Look): void {
  const W = img.width, H = img.height, l = look ?? lookAround(img, b);
  const mx = Math.max(2, b.w * 0.08), my = Math.max(2, b.h * 0.18);
  const x0 = Math.max(1, Math.floor(b.x - mx)), x1 = Math.min(W - 2, Math.ceil(b.x + b.w + mx));
  const y0 = Math.max(1, Math.floor(b.y - my)), y1 = Math.min(H - 2, Math.ceil(b.y + b.h + my));
  const w = x1 - x0, h = y1 - y0;
  if (w < 3 || h < 3) return;
  const px = (x: number, y: number) => { const i = (y * W + x) * 4; return [img.data[i]!, img.data[i + 1]!, img.data[i + 2]!]; };
  // each side's pixels, smoothed along the side (a few pixels outside the region)
  const side = (n: number, at: (k: number) => [number, number]) => {
    const raw = Array.from({ length: n }, (_, k) => { const [x, y] = at(k); return px(x, y); });
    const R = Math.max(1, Math.round(n / 24));
    return raw.map((_, k) => { const s = [0, 0, 0]; let c = 0; for (let j = Math.max(0, k - R); j <= Math.min(n - 1, k + R); j++) { s[0]! += raw[j]![0]!; s[1]! += raw[j]![1]!; s[2]! += raw[j]![2]!; c++; } return s.map((v) => v / c); });
  };
  const L = side(h, (k) => [x0 - 1, y0 + k]), Rt = side(h, (k) => [x1, y0 + k]), T = side(w, (k) => [x0 + k, y0 - 1]), B = side(w, (k) => [x0 + k, y1]);
  const TL = px(x0 - 1, y0 - 1), TR = px(x1, y0 - 1), BL = px(x0 - 1, y1), BR = px(x1, y1);
  // how busy the surround is: the sides disagree
  const diff = (a: number[][], c: number[][]) => a.reduce((s, v, k) => s + Math.abs(v[0]! - c[k]![0]!) + Math.abs(v[1]! - c[k]![1]!) + Math.abs(v[2]! - c[k]![2]!), 0) / (a.length * 3);
  const busy = Math.max(diff(L, Rt), diff(T, B)) > 45;
  const fill = new Float32Array(w * h * 3);
  for (let yy = 0; yy < h; yy++) for (let xx = 0; xx < w; xx++) {
    const u = (xx + 0.5) / w, v = (yy + 0.5) / h, o = (yy * w + xx) * 3;
    for (let c = 0; c < 3; c++) {
      fill[o + c] = (1 - u) * L[yy]![c]! + u * Rt[yy]![c]! + (1 - v) * T[xx]![c]! + v * B[xx]![c]!
        - ((1 - u) * (1 - v) * TL[c]! + u * (1 - v) * TR[c]! + (1 - u) * v * BL[c]! + u * v * BR[c]!);
    }
  }
  if (busy) {
    // a soft blur matched to the bumper on a busy surround
    for (let pass = 0; pass < 2; pass++) {
      const copy = new Float32Array(fill), r = Math.max(1, Math.round(Math.min(w, h) / 10));
      for (let yy = 0; yy < h; yy++) for (let xx = 0; xx < w; xx++) for (let c = 0; c < 3; c++) {
        let s = 0, n = 0;
        for (let k = -r; k <= r; k++) { const a = xx + k; if (a >= 0 && a < w) { s += copy[(yy * w + a) * 3 + c]!; n++; } }
        for (let k = -r; k <= r; k++) { const a = yy + k; if (a >= 0 && a < h) { s += copy[(a * w + xx) * 3 + c]!; n++; } }
        fill[(yy * w + xx) * 3 + c] = s / n;
      }
    }
  }
  for (let yy = 0; yy < h; yy++) for (let xx = 0; xx < w; xx++) {
    const x = x0 + xx, y = y0 + yy;
    // fully filled over the plate, feathered to nothing at the region's edge
    const fx = Math.min(1, Math.min(x - x0, x1 - 1 - x) / Math.max(1, mx)), fy = Math.min(1, Math.min(y - y0, y1 - 1 - y) / Math.max(1, my));
    const a = Math.min(1, Math.min(fx, fy) * 1.2);
    const n = hash(x, y) * l.grain * 2, i = (y * W + x) * 4, o = (yy * w + xx) * 3;
    for (let c = 0; c < 3; c++) img.data[i + c] = img.data[i + c]! + (Math.max(0, Math.min(255, fill[o + c]! + n)) - img.data[i + c]!) * a;
  }
}

/** Every plate of a photo: the front ones edited out, the rear ones made the CARMA plate. Boxes in pixels. In place. */
export function applyPlates(img: Rgba, boxes: PxBox[], end: PlateEnd, text?: string): void {
  for (const b of boxes) {
    const look = lookAround(img, b);
    if (end === 'front') removePlate(img, b, look);
    else { const q = plateQuad(img, b); removePlate(img, b, look); drawPlate(img, q, look, text); }
  }
}
