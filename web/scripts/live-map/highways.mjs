// The Live map's Greater Toronto Area highways (Release 25): the 401, 404, 410, 427, QEW, Don Valley Parkway and
// Gardiner Expressway, with the 400, 403 and 407 so the area keeps them, drawn by hand from public knowledge of their
// routes and simplified to a few points between interchanges (about 1 km accurate: enough for a wall map, not for
// directions). No third-party data: CarmaCars' own work, free to use. Writes web/public/live-map/highways.geojson and
// takes Natural Earth's coarser roads out of the same area of web/public/live-map/basemap.geojson, so no highway is
// drawn twice. Run again only to change a line:
//
//   node scripts/live-map/highways.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = path.join(WEB, 'public/live-map/highways.geojson');
const BASE = path.join(WEB, 'public/live-map/basemap.geojson');
/** [west, south, east, north]: where these lines replace Natural Earth's. */
export const GTA = [-79.95, 43.33, -78.75, 44.12];

/** [ref, name, kind, [lng, lat] ...]: kind "express" for the 400-series and the QEW, "parkway" for the DVP and the Gardiner. */
const LINES = [
  ['401', 'Highway 401', 'express', [
    [-79.985, 43.497], [-79.946, 43.508], [-79.918, 43.519], [-79.885, 43.532], [-79.855, 43.547], [-79.83, 43.563], [-79.808, 43.578],
    [-79.78, 43.588], [-79.752, 43.598], [-79.728, 43.611], [-79.705, 43.624], [-79.688, 43.633], [-79.672, 43.641], [-79.648, 43.651],
    [-79.628, 43.658], [-79.606, 43.665], [-79.592, 43.672], [-79.578, 43.686], [-79.562, 43.701], [-79.54, 43.712], [-79.524, 43.719],
    [-79.506, 43.722], [-79.486, 43.725], [-79.462, 43.729], [-79.447, 43.731], [-79.422, 43.739], [-79.406, 43.745], [-79.386, 43.752],
    [-79.366, 43.759], [-79.345, 43.765], [-79.318, 43.772], [-79.3, 43.776], [-79.279, 43.781], [-79.247, 43.789], [-79.224, 43.794],
    [-79.199, 43.801], [-79.167, 43.803], [-79.142, 43.806], [-79.115, 43.816], [-79.087, 43.828], [-79.06, 43.839], [-79.035, 43.851],
    [-79.0, 43.86], [-78.96, 43.864], [-78.94, 43.866], [-78.912, 43.869], [-78.885, 43.876], [-78.862, 43.882], [-78.835, 43.888],
    [-78.795, 43.894], [-78.745, 43.902], [-78.7, 43.906]]],
  ['QEW', 'Queen Elizabeth Way', 'express', [
    [-79.556, 43.616], [-79.582, 43.603], [-79.603, 43.59], [-79.62, 43.578], [-79.646, 43.559], [-79.668, 43.54], [-79.682, 43.525],
    [-79.69, 43.513], [-79.696, 43.495], [-79.704, 43.476], [-79.718, 43.463], [-79.738, 43.447], [-79.752, 43.433], [-79.775, 43.411],
    [-79.791, 43.396], [-79.806, 43.38], [-79.816, 43.366], [-79.826, 43.352], [-79.835, 43.342], [-79.822, 43.327], [-79.8, 43.306]]],
  ['427', 'Highway 427', 'express', [
    [-79.556, 43.616], [-79.566, 43.628], [-79.578, 43.644], [-79.587, 43.658], [-79.592, 43.672], [-79.598, 43.692], [-79.602, 43.715],
    [-79.606, 43.74], [-79.611, 43.762], [-79.621, 43.788], [-79.632, 43.815], [-79.638, 43.84]]],
  ['404', 'Highway 404', 'express', [
    [-79.343, 43.765], [-79.342, 43.778], [-79.349, 43.793], [-79.356, 43.812], [-79.362, 43.835], [-79.367, 43.852], [-79.372, 43.871],
    [-79.378, 43.9], [-79.383, 43.93], [-79.387, 43.96], [-79.392, 43.985], [-79.401, 44.012], [-79.412, 44.045], [-79.421, 44.075],
    [-79.428, 44.105], [-79.436, 44.13]]],
  ['DVP', 'Don Valley Parkway', 'parkway', [
    [-79.353, 43.653], [-79.357, 43.664], [-79.358, 43.676], [-79.351, 43.687], [-79.338, 43.697], [-79.333, 43.708], [-79.331, 43.721],
    [-79.333, 43.735], [-79.338, 43.748], [-79.343, 43.765]]],
  ['Gardiner', 'Gardiner Expressway', 'parkway', [
    [-79.556, 43.616], [-79.537, 43.619], [-79.516, 43.621], [-79.497, 43.624], [-79.484, 43.628], [-79.472, 43.632], [-79.459, 43.635],
    [-79.443, 43.635], [-79.428, 43.634], [-79.412, 43.636], [-79.398, 43.638], [-79.383, 43.641], [-79.37, 43.645], [-79.36, 43.649],
    [-79.353, 43.653]]],
  ['410', 'Highway 410', 'express', [
    [-79.672, 43.641], [-79.682, 43.66], [-79.696, 43.68], [-79.71, 43.699], [-79.727, 43.718], [-79.746, 43.738], [-79.77, 43.756],
    [-79.802, 43.77], [-79.845, 43.781]]],
  ['400', 'Highway 400', 'express', [
    [-79.524, 43.719], [-79.528, 43.745], [-79.532, 43.772], [-79.535, 43.79], [-79.539, 43.83], [-79.546, 43.873], [-79.56, 43.918],
    [-79.576, 43.965], [-79.588, 44.02], [-79.598, 44.075], [-79.608, 44.13]]],
  ['403', 'Highway 403', 'express', [
    [-79.672, 43.641], [-79.66, 43.62], [-79.649, 43.603], [-79.668, 43.594], [-79.698, 43.583], [-79.72, 43.567], [-79.728, 43.546],
    [-79.712, 43.526], [-79.69, 43.513]]],
  ['407', 'Highway 407', 'express', [
    [-79.835, 43.342], [-79.833, 43.39], [-79.83, 43.425], [-79.818, 43.47], [-79.809, 43.52], [-79.806, 43.56], [-79.808, 43.578],
    [-79.794, 43.606], [-79.764, 43.619], [-79.722, 43.656], [-79.68, 43.696], [-79.664, 43.722], [-79.64, 43.752], [-79.6, 43.768],
    [-79.557, 43.782], [-79.535, 43.79], [-79.483, 43.802], [-79.46, 43.818], [-79.42, 43.834], [-79.367, 43.852], [-79.3, 43.866],
    [-79.24, 43.874], [-79.199, 43.879], [-79.15, 43.899], [-79.105, 43.915], [-79.04, 43.93], [-78.96, 43.944], [-78.88, 43.955],
    [-78.8, 43.968], [-78.72, 43.982]]]
];

const inGta = ([x, y]) => x > GTA[0] && x < GTA[2] && y > GTA[1] && y < GTA[3];

export function build() {
  return {
    type: 'FeatureCollection',
    attribution: 'GTA highways: CarmaCars, simplified by hand',
    features: LINES.map(([ref, name, kind, coords]) => ({ type: 'Feature', properties: { k: 'hwy', ref, name, kind }, geometry: { type: 'LineString', coordinates: coords } }))
  };
}

/** Natural Earth's road lines with every point inside the area taken out (a line split where it crosses it). */
export function stripRoads(base) {
  const features = [];
  for (const f of base.features) {
    if (f.properties?.k !== 'road') { features.push(f); continue; }
    const out = [];
    for (const line of f.geometry.coordinates) {
      let run = [];
      for (const pt of line) {
        if (inGta(pt)) { if (run.length >= 2) out.push(run); run = []; } else run.push(pt);
      }
      if (run.length >= 2) out.push(run);
    }
    if (out.length) features.push({ ...f, geometry: { type: 'MultiLineString', coordinates: out } });
  }
  return { ...base, features };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const hwy = build();
  fs.writeFileSync(OUT, JSON.stringify(hwy) + '\n');
  const base = JSON.parse(fs.readFileSync(BASE, 'utf8'));
  const stripped = stripRoads(base);
  fs.writeFileSync(BASE, JSON.stringify(stripped) + '\n');
  const roads = (d) => d.features.filter((f) => f.properties.k === 'road').reduce((n, f) => n + f.geometry.coordinates.length, 0);
  console.log(`${path.relative(WEB, OUT)}: ${hwy.features.length} highways (${hwy.features.map((f) => f.properties.ref).join(' ')}); basemap road lines ${roads(base)} -> ${roads(stripped)}`);
}
