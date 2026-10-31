// The Live map's own basemap (Release 24): water and the major highways of southern Ontario from Natural Earth (public
// domain, naturalearthdata.com), simplified, plus the city labels. Writes web/public/live-map/basemap.geojson, which the
// page draws with MapLibre (no tile service, the same with or without internet). Run again only to change the area.
//
//   curl -sSLO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_lakes.geojson
//   curl -sSLO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_roads.geojson
//   node scripts/live-map/basemap.mjs ne_10m_lakes.geojson ne_10m_roads.geojson
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = path.join(WEB, 'public/live-map/basemap.geojson');
const [lakesFile, roadsFile] = process.argv.slice(2);
if (!lakesFile || !roadsFile) { console.error('usage: node scripts/live-map/basemap.mjs ne_10m_lakes.geojson ne_10m_roads.geojson'); process.exit(2); }

// southern Ontario (the map's farthest zoom out), a little wider so shores run off the edge
const BOX = [-84.5, 41.2, -73.5, 47.2];
const inBox = ([x, y]) => x >= BOX[0] && x <= BOX[2] && y >= BOX[1] && y <= BOX[3];
const round = (c) => [Math.round(c[0] * 1e4) / 1e4, Math.round(c[1] * 1e4) / 1e4];

/** Douglas-Peucker on [lng, lat] (degrees; good enough at this scale). */
function simplify(pts, tol) {
  if (pts.length < 3) return pts;
  const keep = new Uint8Array(pts.length); keep[0] = keep[pts.length - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const [ax, ay] = pts[a], [bx, by] = pts[b], dx = bx - ax, dy = by - ay, len = Math.hypot(dx, dy) || 1e-12;
    let far = -1, dmax = 0;
    for (let i = a + 1; i < b; i++) {
      const d = Math.abs(dy * pts[i][0] - dx * pts[i][1] + bx * ay - by * ax) / len;
      if (d > dmax) { dmax = d; far = i; }
    }
    if (dmax > tol && far > 0) { keep[far] = 1; stack.push([a, far], [far, b]); }
  }
  return pts.filter((_, i) => keep[i]);
}
/** A closed ring: simplified as two halves (one line from a point back to itself has no length to measure from). */
function simplifyRing(r, tol) {
  const m = Math.floor(r.length / 2);
  return [...simplify(r.slice(0, m + 1), tol).slice(0, -1), ...simplify(r.slice(m), tol)];
}
const dedupe = (pts) => pts.filter((p, i) => i === 0 || p[0] !== pts[i - 1][0] || p[1] !== pts[i - 1][1]);

const features = [];
// water: every lake that reaches the area (the Great Lakes, Georgian Bay, Lake Simcoe and the smaller ones)
for (const f of JSON.parse(fs.readFileSync(lakesFile, 'utf8')).features) {
  const g = f.geometry, polys = g.type === 'Polygon' ? [g.coordinates] : g.coordinates;
  if (!polys.some((p) => p.some((r) => r.some(inBox)))) continue;
  const out = polys.map((p) => p.map((r) => dedupe(simplifyRing(r, 0.004).map(round))).filter((r) => r.length >= 4)).filter((p) => p.length);
  if (out.length) features.push({ type: 'Feature', properties: { k: 'water', name: f.properties.name ?? '' }, geometry: { type: 'MultiPolygon', coordinates: out } });
}
// highways: Natural Earth's major highways and beltways in the area (the 400-series, the QEW and the US interstates across the border)
for (const f of JSON.parse(fs.readFileSync(roadsFile, 'utf8')).features) {
  const p = f.properties;
  if (!['Major Highway', 'Beltway'].includes(p.type)) continue;
  const g = f.geometry, lines = g.type === 'LineString' ? [g.coordinates] : g.coordinates;
  if (!lines.some((l) => l.some(inBox))) continue;
  const out = lines.map((l) => dedupe(simplify(l, 0.003).map(round))).filter((l) => l.length >= 2);
  if (out.length) features.push({ type: 'Feature', properties: { k: 'road', ref: String(p.name ?? '') }, geometry: { type: 'MultiLineString', coordinates: out } });
}
// the city labels (rank 1 first when labels collide)
const CITIES = [['Toronto', -79.383, 43.653, 1], ['Mississauga', -79.644, 43.589, 2], ['Brampton', -79.762, 43.731, 2], ['Vaughan', -79.508, 43.837, 3],
  ['Markham', -79.337, 43.857, 3], ['Oakville', -79.687, 43.467, 3], ['Hamilton', -79.866, 43.256, 2], ['Oshawa', -78.865, 43.897, 2], ['Barrie', -79.69, 44.389, 2],
  ['Kitchener', -80.493, 43.452, 2], ['St. Catharines', -79.247, 43.159, 3], ['Peterborough', -78.32, 44.3, 3]];
for (const [name, x, y, rank] of CITIES) features.push({ type: 'Feature', properties: { k: 'city', name, rank }, geometry: { type: 'Point', coordinates: [x, y] } });

const json = JSON.stringify({ type: 'FeatureCollection', attribution: 'Natural Earth (public domain)', features });
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, json + '\n');
const roads = features.filter((f) => f.properties.k === 'road').map((f) => f.properties.ref);
console.log(`${path.relative(WEB, OUT)}: ${Math.round(json.length / 1024)} KB, ${features.filter((f) => f.properties.k === 'water').length} water, ${roads.length} highways (${[...new Set(roads)].filter(Boolean).sort().join(' ')})`);
