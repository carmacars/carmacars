// Polygon coverage for the drawings made without a canvas (the showroom's logo and lettering, the CARMA plate). Pure.
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
