// Interior photos and what shows through the windows (r27 leftovers, migration 0521; docs/changes/2026-11-07-r27-leftovers.md
// section 3). A dashboard or seats photo shows the street, a car park or a neighbour's house through the windows. The
// worker cuts the interior out (the same segmentation as the outside photos, segment=foreground) and reads the cut-out's
// transparency here: the transparent part is what the segmenter saw through the windows.
//
// The quality check (all four must hold, else the windows are blurred instead):
//   1. some, not most: 3% to 40% of the frame is see-through (under 3%: no window seen, the photo is kept as edited)
//   2. where windows are: at least 75% of the see-through part is in the top 65% of the frame (a seat or the floor cut
//      away lower down means the segmenter lost the interior)
//   3. few clean regions: at most 6 see-through regions of 1% of the frame or more, at most 12 specks under 0.3%
//   4. clean edges: at most 6% of the pixels half transparent (a mushy matte shows as a halo)
// Pass: the studio background is placed behind the interior, so the windows show the studio ("replace"). Fail: the
// original is blurred behind the cut-out, so the windows show a soft blur of what was there ("blur"); a wrong cut can
// then only blur a part of the same photo, never paste the studio into the cabin. No PNG, or one this reader does not
// know: "blur". Pure and dependency free (the Worker and the unit tests run it); the PNG is inflated with the
// platform's DecompressionStream.

export interface AlphaGrid { w: number; h: number; /** per cell, the share of see-through pixels (alpha under 128) */ clear: Float32Array; soft: number }
export type WindowPlan = { action: 'replace' | 'blur' | 'none'; reasons: string[]; metrics: Record<string, number> };

export const GRID = { w: 48, h: 32 };
export const RULES = { minClear: 0.03, maxClear: 0.4, topShare: 0.65, minTop: 0.75, regionMin: 0.01, maxRegions: 6, speck: 0.003, maxSpecks: 12, maxSoft: 0.06 };

const u32 = (b: Uint8Array, o: number) => ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0;

async function inflate(data: Uint8Array): Promise<Uint8Array> {
  const ds = new DecompressionStream('deflate');
  const out = new Response(new Blob([data as BlobPart]).stream().pipeThrough(ds));
  return new Uint8Array(await out.arrayBuffer());
}

/** The cut-out's transparency on a coarse grid; null when it is not an 8-bit, non-interlaced PNG with alpha. */
export async function readAlpha(png: Uint8Array, grid = GRID): Promise<AlphaGrid | null> {
  if (png.length < 33 || u32(png, 0) !== 0x89504e47 || u32(png, 4) !== 0x0d0a1a0a) return null;
  let o = 8, width = 0, height = 0, depth = 0, colour = 0, interlace = 0;
  const idat: Uint8Array[] = [];
  while (o + 8 <= png.length) {
    const len = u32(png, o), type = String.fromCharCode(png[o + 4]!, png[o + 5]!, png[o + 6]!, png[o + 7]!);
    const body = png.subarray(o + 8, o + 8 + len);
    if (type === 'IHDR') { width = u32(body, 0); height = u32(body, 4); depth = body[8]!; colour = body[9]!; interlace = body[12]!; }
    else if (type === 'IDAT') idat.push(body);
    else if (type === 'IEND') break;
    o += 12 + len;
  }
  const bpp = colour === 6 ? 4 : colour === 4 ? 2 : 0;
  if (!width || !height || depth !== 8 || !bpp || interlace !== 0 || !idat.length) return null;
  const joined = new Uint8Array(idat.reduce((n, c) => n + c.length, 0));
  let at = 0; for (const c of idat) { joined.set(c, at); at += c.length; }
  let raw: Uint8Array;
  try { raw = await inflate(joined); } catch { return null; }
  const stride = width * bpp;
  if (raw.length < height * (stride + 1)) return null;
  const clearCount = new Float32Array(grid.w * grid.h), cellSize = new Float32Array(grid.w * grid.h);
  let soft = 0;
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
    const gy = Math.min(grid.h - 1, Math.floor((y * grid.h) / height));
    for (let x = 0; x < width; x++) {
      const al = cur[x * bpp + bpp - 1]!;
      const gi = gy * grid.w + Math.min(grid.w - 1, Math.floor((x * grid.w) / width));
      cellSize[gi]!++;
      if (al < 128) clearCount[gi]!++;
      if (al >= 16 && al <= 239) soft++;
    }
    [prev, cur] = [cur, prev];
  }
  const clear = new Float32Array(grid.w * grid.h);
  for (let i = 0; i < clear.length; i++) clear[i] = cellSize[i] ? clearCount[i]! / cellSize[i]! : 0;
  return { w: grid.w, h: grid.h, clear, soft: soft / (width * height) };
}

/** The quality check above, on the grid: replace or none (r44: never blur), with the measures and the rules that failed. */
export function windowPlan(g: AlphaGrid | null): WindowPlan {
  // r44: a cut-out that fails the check keeps the photo sharp as taken ("none"): the old "blur" blurred everything the
  // segmenter did not keep (on a dashboard photo it often kept only the steering wheel), so the cabin came out soft with an
  // artificial focus on the wheel. An interior is never blurred now.
  if (!g) return { action: 'none', reasons: ['the cut-out could not be read'], metrics: {} };
  const n = g.w * g.h;
  const on = Array.from(g.clear, (c) => c >= 0.5);
  const total = on.filter(Boolean).length;
  const share = total / n;
  const topRows = Math.round(g.h * RULES.topShare);
  const top = on.filter((v, i) => v && Math.floor(i / g.w) < topRows).length;
  // the see-through regions (4-neighbour)
  const seen = new Uint8Array(n);
  const sizes: number[] = [];
  for (let i = 0; i < n; i++) {
    if (!on[i] || seen[i]) continue;
    let size = 0; const stack = [i]; seen[i] = 1;
    while (stack.length) {
      const k = stack.pop()!; size++;
      const x = k % g.w, y = Math.floor(k / g.w);
      for (const [nx, ny] of [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]] as const) {
        if (nx < 0 || ny < 0 || nx >= g.w || ny >= g.h) continue;
        const j = ny * g.w + nx;
        if (on[j] && !seen[j]) { seen[j] = 1; stack.push(j); }
      }
    }
    sizes.push(size / n);
  }
  const regions = sizes.filter((s) => s >= RULES.regionMin).length, specks = sizes.filter((s) => s < RULES.speck).length;
  const metrics = { clear: +share.toFixed(4), top: total ? +(top / total).toFixed(4) : 0, regions, specks, soft: +g.soft.toFixed(4) };
  if (share < RULES.minClear) return { action: 'none', reasons: ['no window seen'], metrics };
  const reasons: string[] = [];
  if (share > RULES.maxClear) reasons.push(`${Math.round(share * 100)}% see-through, more than ${RULES.maxClear * 100}%`);
  if (top / total < RULES.minTop) reasons.push('see-through parts low in the frame');
  if (regions > RULES.maxRegions) reasons.push(`${regions} see-through regions, more than ${RULES.maxRegions}`);
  if (specks > RULES.maxSpecks) reasons.push(`${specks} specks, more than ${RULES.maxSpecks}`);
  if (g.soft > RULES.maxSoft) reasons.push(`${Math.round(g.soft * 100)}% half-transparent edge, more than ${RULES.maxSoft * 100}%`);
  return { action: reasons.length ? 'none' : 'replace', reasons, metrics };
}

/** The interior shots whose windows are treated (the others are edited as before). */
export const WINDOW_SHOTS = ['dashboard', 'front_seats', 'rear_seats'];
