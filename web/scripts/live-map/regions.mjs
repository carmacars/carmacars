// The Live map's land (Release 26): every municipality's outline (the GTA's regions marked), the major arterial roads,
// the cities and towns, a soft glow where people live, and the two ridges that give the land its shape (the Niagara
// Escarpment and the Oak Ridges Moraine). Writes
// web/public/live-map/regions.geojson, which the page draws under the water, so the land carries the map and the lake
// stays quiet. Run again only to change the area:
//
//   curl -sSLO https://media.githubusercontent.com/media/wmgeolab/geoBoundaries/main/releaseData/gbOpen/CAN/ADM3/geoBoundaries-CAN-ADM3.geojson
//   node scripts/live-map/regions.mjs geoBoundaries-CAN-ADM3.geojson
//
// The boundaries: Statistics Canada's 2016 census subdivisions through geoBoundaries (ODbL 1.0; Statistics Canada Open
// Licence). Each shared border is simplified once, so neighbours keep meeting exactly (the same idea as TopoJSON). The
// populations (2021 census, rounded) only shade the glow. The two ridges are drawn by hand from public knowledge of
// where they run (a few km accurate: atmosphere for a wall map, not survey data), CarmaCars' own work.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = path.join(WEB, 'public/live-map/regions.geojson');

/** [west, south, east, north]: the municipalities whose middle is in here (the TV's view and a margin). */
export const AREA = [-80.9, 42.9, -77.7, 44.8];
/** The GTA's five regions and Hamilton, by municipality. */
export const REGIONS = {
  Toronto: ['Toronto'],
  Peel: ['Mississauga', 'Brampton', 'Caledon'],
  York: ['Vaughan', 'Markham', 'Richmond Hill', 'King', 'Aurora', 'Newmarket', 'Whitchurch-Stouffville', 'East Gwillimbury', 'Georgina', 'Chippewas of Georgina Island *'],
  Durham: ['Pickering', 'Ajax', 'Whitby', 'Oshawa', 'Clarington', 'Scugog', 'Uxbridge', 'Brock', 'Mississaugas of Scugog Island'],
  Halton: ['Burlington', 'Oakville', 'Milton', 'Halton Hills'],
  Hamilton: ['Hamilton']
};
/** 2021 census populations (thousands, rounded): the glow is brighter where more people live per km². */
const POP = {
  Toronto: 2794, Mississauga: 717, Brampton: 656, Hamilton: 569, Markham: 338, Vaughan: 323, Kitchener: 256, Oakville: 213, 'Richmond Hill': 202,
  Burlington: 186, Oshawa: 175, Barrie: 147, Guelph: 144, Cambridge: 138, Whitby: 138, 'St. Catharines': 136, Milton: 132, Ajax: 126, Waterloo: 121,
  Brantford: 104, Clarington: 101, Pickering: 99, 'Niagara Falls': 94, Newmarket: 88, Peterborough: 83, Caledon: 77, 'Halton Hills': 62, Aurora: 62,
  'Whitchurch-Stouffville': 49, Georgina: 47, Innisfil: 43, 'Bradford West Gwillimbury': 43, 'East Gwillimbury': 35, Orangeville: 30, King: 27,
  Grimsby: 29, Lincoln: 26, Thorold: 23, 'Port Hope': 17, Cobourg: 20, Uxbridge: 22, Scugog: 22, 'New Tecumseth': 43, Woolwich: 26, 'Centre Wellington': 31
};
/** Where each region's name sits (clear of the cities' labels). */
/** The cities and towns between the ones the basemap names: [name, lng, lat, rank]. Rank 3 are the GTA's cities the
 * owner listed (as large as the basemap's smaller cities), rank 4 smaller towns that give way to everything else. */
const TOWNS = [['Richmond Hill', -79.437, 43.882, 3], ['Burlington', -79.8, 43.33, 3], ['Pickering', -79.09, 43.838, 3], ['Ajax', -79.032, 43.851, 3],
  ['Whitby', -78.943, 43.898, 3], ['Milton', -79.88, 43.515, 3], ['Newmarket', -79.462, 44.059, 3], ['Aurora', -79.467, 44.006, 3],
  ['Guelph', -80.248, 43.545, 4], ['Cambridge', -80.312, 43.36, 4], ['Bolton', -79.733, 43.875, 4], ['Georgetown', -79.918, 43.65, 4], ['Bowmanville', -78.688, 43.912, 4],
  ['Stouffville', -79.245, 43.971, 4], ['Uxbridge', -79.123, 44.109, 4], ['Bradford', -79.566, 44.115, 4], ['Innisfil', -79.58, 44.3, 4], ['King City', -79.528, 43.926, 4],
  ['Grimsby', -79.561, 43.2, 4], ['Port Perry', -78.945, 44.105, 4], ['Orangeville', -80.097, 43.92, 4], ['Caledon East', -79.86, 43.873, 4]];
/** Major arterial roads, drawn by hand from public knowledge of their routes (about 1 km accurate: a wall map's
 * texture, not directions), CarmaCars' own work: [name, [lng, lat] ...]. */
const ARTERIALS = [
  ['Yonge Street', [[-79.377, 43.642], [-79.379, 43.6525], [-79.3868, 43.671], [-79.3985, 43.7066], [-79.4022, 43.7251], [-79.411, 43.7615], [-79.4155, 43.7804], [-79.4196, 43.7969],
    [-79.425, 43.842], [-79.44, 43.879], [-79.452, 43.93], [-79.466, 44.0], [-79.479, 44.055], [-79.49, 44.1], [-79.55, 44.2], [-79.62, 44.3], [-79.675, 44.385]]],
  ['Bloor Street and Danforth Avenue', [[-79.6, 43.62], [-79.56, 43.629], [-79.536, 43.6372], [-79.5243, 43.6454], [-79.4842, 43.6497], [-79.435, 43.66], [-79.411, 43.6655], [-79.3868, 43.671],
    [-79.358, 43.6766], [-79.345, 43.6796], [-79.301, 43.689], [-79.2885, 43.693]]],
  ['Eglinton Avenue', [[-79.7055, 43.5585], [-79.6505, 43.6055], [-79.612, 43.629], [-79.584, 43.661], [-79.496, 43.6866], [-79.436, 43.699], [-79.3985, 43.7066], [-79.342, 43.721],
    [-79.303, 43.7265], [-79.2637, 43.7323], [-79.218, 43.744], [-79.199, 43.747]]],
  ['Lawrence Avenue', [[-79.515, 43.7], [-79.45, 43.715], [-79.4022, 43.7251], [-79.345, 43.739], [-79.297, 43.747], [-79.24, 43.758], [-79.195, 43.772]]],
  ['Sheppard Avenue', [[-79.53, 43.74], [-79.4622, 43.7497], [-79.411, 43.7615], [-79.3462, 43.7756], [-79.2795, 43.788], [-79.235, 43.798], [-79.188, 43.808]]],
  ['Finch Avenue', [[-79.595, 43.731], [-79.516, 43.758], [-79.467, 43.771], [-79.4155, 43.7804], [-79.35, 43.795], [-79.286, 43.807], [-79.215, 43.818]]],
  ['Steeles Avenue', [[-79.76, 43.67], [-79.7, 43.688], [-79.64, 43.713], [-79.6, 43.747], [-79.5236, 43.7774], [-79.475, 43.7875], [-79.4196, 43.7969], [-79.348, 43.813],
    [-79.295, 43.826], [-79.2555, 43.8325], [-79.2, 43.846], [-79.17, 43.856]]],
  ['Highway 7', [[-79.76, 43.685], [-79.7, 43.71], [-79.65, 43.74], [-79.615, 43.765], [-79.533, 43.792], [-79.495, 43.803], [-79.425, 43.841], [-79.383, 43.851], [-79.322, 43.86],
    [-79.3, 43.864], [-79.26, 43.88], [-79.2, 43.896], [-79.1, 43.92], [-79.0, 43.94]]],
  ['Major Mackenzie Drive', [[-79.62, 43.83], [-79.548, 43.848], [-79.5, 43.86], [-79.44, 43.879], [-79.37, 43.893], [-79.29, 43.91]]],
  ['Lake Shore', [[-79.8, 43.325], [-79.74, 43.39], [-79.67, 43.447], [-79.63, 43.5], [-79.585, 43.552], [-79.538, 43.592], [-79.47, 43.63], [-79.38, 43.64], [-79.32, 43.661]]],
  ['Dundas Street', [[-79.893, 43.335], [-79.825, 43.38], [-79.73, 43.46], [-79.67, 43.52], [-79.618, 43.585], [-79.53, 43.617], [-79.452, 43.657], [-79.38, 43.656], [-79.345, 43.665]]],
  ['Hurontario Street', [[-79.586, 43.553], [-79.627, 43.584], [-79.65, 43.608], [-79.7, 43.655], [-79.76, 43.687], [-79.8, 43.735], [-79.85, 43.79], [-79.93, 43.88]]],
  ['Kingston Road and Highway 2', [[-79.2885, 43.693], [-79.199, 43.747], [-79.14, 43.79], [-79.09, 43.835], [-79.03, 43.86], [-78.94, 43.877], [-78.865, 43.897], [-78.79, 43.91],
    [-78.688, 43.912]]],
  ['Taunton Road', [[-79.12, 43.88], [-79.04, 43.9], [-78.96, 43.92], [-78.875, 43.945], [-78.75, 43.97]]],
  ['Simcoe Street', [[-78.865, 43.87], [-78.88, 43.97], [-78.9, 44.05], [-78.945, 44.1]]],
  ['Trafalgar Road', [[-79.67, 43.447], [-79.7, 43.47], [-79.76, 43.52], [-79.82, 43.57], [-79.88, 43.64]]],
  ['Brant Street and Guelph Line', [[-79.799, 43.326], [-79.83, 43.37], [-79.88, 43.43], [-79.95, 43.5]]],
  ['Main Street, Hamilton', [[-79.93, 43.26], [-79.871, 43.2557], [-79.82, 43.245], [-79.74, 43.22], [-79.64, 43.2]]],
  ['Upper James Street', [[-79.869, 43.25], [-79.88, 43.2], [-79.89, 43.15]]],
  ['Markham Road and Highway 48', [[-79.218, 43.744], [-79.235, 43.79], [-79.2555, 43.8325], [-79.26, 43.88], [-79.28, 43.95], [-79.3, 44.03], [-79.33, 44.12]]],
  ['Don Mills Road', [[-79.345, 43.705], [-79.342, 43.721], [-79.3462, 43.7756], [-79.357, 43.81], [-79.37, 43.85]]],
  ['Keele Street', [[-79.46, 43.655], [-79.473, 43.69], [-79.4855, 43.7505], [-79.49, 43.783], [-79.495, 43.803], [-79.51, 43.86], [-79.53, 43.93]]],
  ['Kennedy Road', [[-79.255, 43.7], [-79.2637, 43.7323], [-79.275, 43.78], [-79.29, 43.825], [-79.3, 43.864], [-79.31, 43.9]]],
  ['Airport Road', [[-79.62, 43.69], [-79.64, 43.713], [-79.69, 43.77], [-79.74, 43.83], [-79.8, 43.9], [-79.86, 43.97]]],
  ['Burnhamthorpe Road', [[-79.745, 43.53], [-79.69, 43.56], [-79.64, 43.59], [-79.6, 43.62], [-79.55, 43.645]]],
  ['Bayfield Street and Highway 26, Barrie', [[-79.69, 44.39], [-79.7, 44.43], [-79.75, 44.47]]],
  ['Essa Road, Barrie', [[-79.69, 44.385], [-79.74, 44.35], [-79.79, 44.31]]]
];
const REGION_LABELS = [['Peel', -79.86, 43.86], ['York', -79.43, 44.12], ['Durham', -78.92, 44.16], ['Halton', -80.0, 43.55]];
/** [name, [lng, lat] ...]: the brow of the escarpment from Niagara round Hamilton and north to the Blue Mountains, and the moraine's crest from Caledon east to Rice Lake. */
const RIDGES = [
  ['Niagara Escarpment', [[-79.05, 43.16], [-79.18, 43.14], [-79.3, 43.135], [-79.42, 43.15], [-79.56, 43.19], [-79.68, 43.21], [-79.78, 43.225], [-79.87, 43.235],
    [-79.95, 43.255], [-79.99, 43.285], [-79.94, 43.33], [-79.92, 43.4], [-79.91, 43.47], [-79.94, 43.55], [-79.97, 43.63], [-79.96, 43.72], [-80.0, 43.79],
    [-79.99, 43.86], [-79.98, 43.93], [-80.03, 43.99], [-80.07, 44.07], [-80.1, 44.16], [-80.17, 44.27], [-80.27, 44.38], [-80.33, 44.47]]],
  ['Oak Ridges Moraine', [[-80.0, 43.92], [-79.88, 43.93], [-79.76, 43.95], [-79.64, 43.96], [-79.53, 43.96], [-79.44, 43.97], [-79.34, 44.01], [-79.22, 44.05],
    [-79.1, 44.08], [-78.98, 44.09], [-78.86, 44.08], [-78.74, 44.07], [-78.6, 44.08], [-78.47, 44.1], [-78.34, 44.13]]]
];

const Q = 1e5;
const q = ([x, y]) => [Math.round(x * Q) / Q, Math.round(y * Q) / Q];
const key = (p) => `${p[0]},${p[1]}`;
const round4 = ([x, y]) => [Math.round(x * 1e4) / 1e4, Math.round(y * 1e4) / 1e4];

/** Douglas-Peucker on [lng, lat]; the ends stay. */
export function simplify(pts, tol) {
  if (pts.length < 3) return pts;
  const keep = new Uint8Array(pts.length); keep[0] = keep[pts.length - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const [ax, ay] = pts[a], [bx, by] = pts[b], dx = bx - ax, dy = by - ay, len = Math.hypot(dx, dy);
    let far = -1, dmax = 0;
    for (let i = a + 1; i < b; i++) {
      const d = len ? Math.abs(dy * pts[i][0] - dx * pts[i][1] + bx * ay - by * ax) / len : Math.hypot(pts[i][0] - ax, pts[i][1] - ay);
      if (d > dmax) { dmax = d; far = i; }
    }
    if (dmax > tol && far > 0) { keep[far] = 1; stack.push([a, far], [far, b]); }
  }
  return pts.filter((_, i) => keep[i]);
}

/** Splits every ring into arcs where its neighbour changes, simplifies each arc once, and puts the rings back together. */
/** `tolOf`: a tolerance in degrees, or a function of the arc's units (indexes into `units`) giving one. */
export function topology(units, tolOf) {
  const edges = new Map();
  const ek = (a, b) => { const x = key(a), y = key(b); return x < y ? `${x}|${y}` : `${y}|${x}`; };
  for (const [i, u] of units.entries()) for (const poly of u.polys) for (const r of poly) for (let j = 0; j + 1 < r.length; j++) {
    const k = ek(r[j], r[j + 1]);
    if (!edges.has(k)) edges.set(k, new Set());
    edges.get(k).add(i);
  }
  const side = (a, b, self) => [...(edges.get(ek(a, b)) ?? [])].filter((x) => x !== self).sort().join(',');
  const arcs = new Map(); // canonical key -> { pts, simple, units:Set }
  const arcOf = (pts, self, other) => {
    const fwd = pts.map(key).join(';'), back = [...pts].reverse().map(key).join(';');
    const k = fwd < back ? fwd : back, flip = k !== fwd;
    if (!arcs.has(k)) { const canon = flip ? [...pts].reverse() : pts; arcs.set(k, { pts: canon, simple: null, units: new Set(), other }); }
    arcs.get(k).units.add(self);
    return { k, flip };
  };
  const rings = units.map((u, i) => u.polys.map((poly) => poly.map((r) => {
    const n = r.length - 1; // closed: r[n] == r[0]
    const nb = (j) => side(r[j % n], r[(j + 1) % n], i);
    let start = -1;
    for (let j = 0; j < n; j++) if (nb((j + n - 1) % n) !== nb(j)) { start = j; break; }
    if (start < 0) return [arcOf([...r.slice(0, n), r[0]], i, nb(0))];
    const out = [];
    let cur = [r[start]], who = nb(start);
    for (let s = 0; s < n; s++) {
      const j = (start + s) % n, next = r[(j + 1) % n];
      cur.push(next);
      const after = nb((j + 1) % n);
      if (s === n - 1 || after !== who) { out.push(arcOf(cur, i, who)); cur = [next]; who = after; }
    }
    return out;
  })));
  for (const a of arcs.values()) {
    const tol = typeof tolOf === 'function' ? tolOf([...a.units]) : tolOf;
    const closed = key(a.pts[0]) === key(a.pts[a.pts.length - 1]);
    a.simple = closed ? (() => { const m = Math.floor(a.pts.length / 2); return [...simplify(a.pts.slice(0, m + 1), tol).slice(0, -1), ...simplify(a.pts.slice(m), tol)]; })() : simplify(a.pts, tol);
    a.simple = a.simple.map(round4).filter((p, j, all) => j === 0 || key(p) !== key(all[j - 1]));
  }
  const polys = rings.map((u) => u.map((poly) => poly.map((r) => {
    const pts = [];
    for (const { k, flip } of r) { const s = flip ? [...arcs.get(k).simple].reverse() : arcs.get(k).simple; pts.push(...(pts.length ? s.slice(1) : s)); }
    if (key(pts[0]) !== key(pts[pts.length - 1])) pts.push(pts[0]);
    return pts;
  }).filter((r) => r.length >= 4)).filter((p) => p.length));
  return { arcs: [...arcs.values()], polys };
}

/** Area in km² (shoelace, degrees scaled at the ring's latitude). */
function areaKm2(polys) {
  let a = 0;
  for (const poly of polys) poly.forEach((r, ri) => {
    let s = 0; const lat = r[0][1], kx = 111.32 * Math.cos((lat * Math.PI) / 180), ky = 110.57;
    for (let j = 0; j + 1 < r.length; j++) s += r[j][0] * kx * r[j + 1][1] * ky - r[j + 1][0] * kx * r[j][1] * ky;
    a += (ri === 0 ? 1 : -1) * Math.abs(s / 2);
  });
  return a;
}
function inRing(x, y, r) {
  let c = false;
  for (let i = 0, j = r.length - 1; i < r.length; j = i++) if ((r[i][1] > y) !== (r[j][1] > y) && x < ((r[j][0] - r[i][0]) * (y - r[i][1])) / (r[j][1] - r[i][1]) + r[i][0]) c = !c;
  return c;
}
/** [minX, minY, maxX, maxY] of the outer rings (a loop: some Canadian rings are too long to spread into Math.min). */
function extent(polys) {
  const e = [Infinity, Infinity, -Infinity, -Infinity];
  for (const p of polys) for (const [x, y] of p[0]) { if (x < e[0]) e[0] = x; if (y < e[1]) e[1] = y; if (x > e[2]) e[2] = x; if (y > e[3]) e[3] = y; }
  return e;
}
const inPolys = (x, y, polys) => polys.some((p) => inRing(x, y, p[0]) && !p.slice(1).some((h) => inRing(x, y, h)));

export function build(src) {
  const regionOf = new Map(Object.entries(REGIONS).flatMap(([r, ms]) => ms.map((m) => [m, r])));
  const units = [];
  for (const f of src.features) {
    const g = f.geometry, name = f.properties.shapeName;
    const polys = (g.type === 'Polygon' ? [g.coordinates] : g.coordinates).map((p) => p.map((r) => r.map(q)));
    const e = extent(polys), cx = (e[0] + e[2]) / 2, cy = (e[1] + e[3]) / 2;
    if (cx < AREA[0] || cx > AREA[2] || cy < AREA[1] || cy > AREA[3]) continue;
    // two places are called Hamilton: the city (west of Toronto) and the township on Rice Lake
    const region = name === 'Hamilton' && cx < -79 ? 'Hamilton' : name === 'Hamilton' ? null : regionOf.get(name) ?? null;
    units.push({ name, region, polys });
  }
  // the GTA's borders finer; the land round it coarser, so the file stays small
  const { arcs, polys } = topology(units, (us) => (us.some((i) => units[i].region) ? 0.0022 : 0.0045));
  const features = [];
  // the GTA's municipalities, each with its region (for the region's tint)
  units.forEach((u, i) => {
    if (!u.region) return;
    features.push({ type: 'Feature', properties: { k: 'muni', name: u.name, region: u.region }, geometry: { type: 'MultiPolygon', coordinates: polys[i] } });
  });
  // the borders: between two regions (or a region and the land around it) and between two municipalities of one region;
  // a coast (one side only) is the water's to draw
  const lines = { region: [], muni: [] };
  for (const a of arcs) {
    // every municipality is outlined (Release 26, the owner: "an outline of each city or municipality"); a border
    // between two GTA regions, or round the GTA, is a region border
    if (a.units.size < 2 || a.simple.length < 2) continue;
    const rs = [...a.units].map((i) => units[i].region);
    lines[rs[0] !== rs[1] && rs.some(Boolean) ? 'region' : 'muni'].push(a.simple);
  }
  // one MultiLineString per level keeps the file small
  for (const [lvl, coordinates] of Object.entries(lines)) features.push({ type: 'Feature', properties: { k: 'border', lvl }, geometry: { type: 'MultiLineString', coordinates } });
  for (const [name, x, y, rank] of TOWNS) features.push({ type: 'Feature', properties: { k: 'town', name, rank }, geometry: { type: 'Point', coordinates: [x, y] } });
  for (const [name, pts] of ARTERIALS) features.push({ type: 'Feature', properties: { k: 'arterial', name }, geometry: { type: 'LineString', coordinates: pts } });
  for (const [name, x, y] of REGION_LABELS) features.push({ type: 'Feature', properties: { k: 'region', name }, geometry: { type: 'Point', coordinates: [x, y] } });
  for (const [name, pts] of RIDGES) features.push({ type: 'Feature', properties: { k: 'ridge', name }, geometry: { type: 'LineString', coordinates: pts } });
  // the glow: a point every 0.03 degrees inside each populated municipality (one MultiPoint each), weighted by its
  // people per km² (Toronto about 1)
  const STEP = 0.03, r2 = (v) => Math.round(v * 100) / 100;
  units.forEach((u) => {
    const pop = POP[u.name === 'Hamilton' && !u.region ? '' : u.name];
    if (!pop) return;
    const w = Math.min(1, (pop * 1000) / areaKm2(u.polys) / 4400);
    if (w < 0.02) return;
    const e = extent(u.polys), x0 = Math.ceil(e[0] / STEP) * STEP, y0 = Math.ceil(e[1] / STEP) * STEP, pts = [];
    for (let x = x0; x < e[2]; x += STEP) for (let y = y0; y < e[3]; y += STEP) if (inPolys(x, y, u.polys)) pts.push([r2(x), r2(y)]);
    // a town smaller than the grid still glows a little, at its middle
    if (!pts.length) pts.push([r2((e[0] + e[2]) / 2), r2((e[1] + e[3]) / 2)]);
    features.push({ type: 'Feature', properties: { k: 'glow', w: r2(w) }, geometry: { type: 'MultiPoint', coordinates: pts } });
  });
  return {
    type: 'FeatureCollection',
    attribution: 'Boundaries: Statistics Canada 2016 census subdivisions via geoBoundaries (ODbL 1.0). Arterial roads and ridges: CarmaCars, drawn by hand',
    features
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const file = process.argv[2];
  if (!file) { console.error('usage: node scripts/live-map/regions.mjs geoBoundaries-CAN-ADM3.geojson'); process.exit(2); }
  const out = build(JSON.parse(fs.readFileSync(file, 'utf8')));
  const json = JSON.stringify(out);
  fs.writeFileSync(OUT, json + '\n');
  const c = (k) => out.features.filter((f) => f.properties.k === k).length;
  console.log(`${path.relative(WEB, OUT)}: ${Math.round(json.length / 1024)} KB, ${c('muni')} municipalities, ${c('border')} borders, ${c('glow')} glow areas, ${c('town')} towns, ${c('arterial')} arterials, ${c('ridge')} ridges`);
}
