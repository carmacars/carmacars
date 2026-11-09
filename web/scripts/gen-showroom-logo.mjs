#!/usr/bin/env node
// The CarmaCars logo for the showroom wall of the listing photos (release 35, features/listing/showroom.ts): the paths of
// public/brand/carma-logo-white.svg (M, L, C and Z only) flattened to polygons, with each path's fill colour, so the
// Worker draws the logo with no SVG renderer and no network.
//   node web/scripts/gen-showroom-logo.mjs     writes src/features/listing/presets/showroom-logo.json
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
const svg = readFileSync(join(WEB, 'public', 'brand', 'carma-logo-white.svg'), 'utf8');
const vb = svg.match(/viewBox="([^"]+)"/)[1].split(/\s+/).map(Number);
const r2 = (n) => Math.round(n * 100) / 100;
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));

const paths = [];
for (const m of svg.matchAll(/<path[^>]*fill="(#[0-9A-Fa-f]{6})"[^>]*d="([^"]+)"/g)) {
  const toks = m[2].match(/[MLCZ]|-?\d*\.?\d+(?:e-?\d+)?/gi);
  const polys = [];
  let cur = [], x = 0, y = 0, cmd = '', i = 0;
  const num = () => Number(toks[i++]);
  while (i < toks.length) {
    if (/^[MLCZ]$/i.test(toks[i])) cmd = toks[i++].toUpperCase();
    if (cmd === 'M') { if (cur.length) polys.push(cur); cur = []; x = num(); y = num(); cur.push(r2(x), r2(y)); cmd = 'L'; }
    else if (cmd === 'L') { x = num(); y = num(); cur.push(r2(x), r2(y)); }
    else if (cmd === 'C') {
      const [x1, y1, x2, y2, x3, y3] = [num(), num(), num(), num(), num(), num()];
      for (let k = 1; k <= 8; k++) {
        const t = k / 8, u = 1 - t;
        cur.push(r2(u * u * u * x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3), r2(u * u * u * y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3));
      }
      x = x3; y = y3;
    } else if (cmd === 'Z') { if (cur.length) polys.push(cur); cur = []; cmd = ''; }
    else throw new Error(`unexpected ${toks[i]}`);
  }
  if (cur.length) polys.push(cur);
  paths.push({ fill: hex(m[1]), polys });
}
const out = { source: 'public/brand/carma-logo-white.svg', viewBox: vb, paths };
writeFileSync(join(WEB, 'src', 'features', 'listing', 'presets', 'showroom-logo.json'), JSON.stringify(out) + '\n');
console.log(`showroom-logo.json: ${paths.length} paths, ${paths.reduce((a, p) => a + p.polys.length, 0)} polygons`);
