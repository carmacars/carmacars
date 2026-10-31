// The Live map (migration 0242): the map library, the tiles and the area it frames. Shared by the page, the content
// security policy (src/lib/security/csp.ts, which allows exactly these origins on /admin/live-map) and the Worker.
// No imports: the Worker entry bundles this file.

/** MapLibre GL JS, one pinned version (BSD-3-Clause), from jsDelivr's npm mirror; loaded in the browser on the map page only. */
export const MAPLIBRE_VERSION = '4.7.1';
export const MAP_CDN = 'https://cdn.jsdelivr.net';
export const MAPLIBRE_JS = `${MAP_CDN}/npm/maplibre-gl@${MAPLIBRE_VERSION}/dist/maplibre-gl.js`;
export const MAPLIBRE_CSS = `${MAP_CDN}/npm/maplibre-gl@${MAPLIBRE_VERSION}/dist/maplibre-gl.css`;
/** OpenFreeMap: free vector tiles from OpenStreetMap data, no key and no limits (openfreemap.org; attribution required). */
export const MAP_TILES = 'https://tiles.openfreemap.org';
export const MAP_STYLE = `${MAP_TILES}/styles/dark`;
export const MAP_ATTRIBUTION = '<a href="https://openfreemap.org" target="_blank" rel="noopener">OpenFreeMap</a> <a href="https://www.openmaptiles.org/" target="_blank" rel="noopener">&copy; OpenMapTiles</a> Data from <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>';

/** [west, south, east, north]. */
export type Bounds = [number, number, number, number];
/** The first view: Kitchener-Waterloo and Guelph, Niagara (St. Catharines), Peterborough and Cobourg, Barrie and Lake Simcoe; Toronto in the middle. */
export const HOME_BOUNDS: Bounds = [-80.62, 42.98, -78.0, 44.68];
/** The farthest the map zooms out or fits to: southern Ontario. A pin outside it is counted, not drawn. */
export const MAX_BOUNDS: Bounds = [-83.6, 41.6, -74.3, 46.6];
export const TORONTO: [number, number] = [-79.3832, 43.6532];

/** Refresh every 30 seconds; the server keeps one answer 20 seconds. */
export const REFRESH_MS = 30_000;
export const CACHE_MS = 20_000;
/** A pin pulses when its last activity is this recent (and while the visitor is on the site). */
export const NEW_MS = 5 * 60_000;
/** The TV spotlight moves to the next lead every 10 seconds. */
export const SPOTLIGHT_MS = 10_000;

/** Cloudflare's request.cf latitude or longitude (a string), rounded to 0.01 degree (about 1 km); null when not a number. */
export function roundGeo(v: unknown): number | null {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  if (!Number.isFinite(n) || Math.abs(n) > 180) return null;
  return Math.round(n * 100) / 100;
}

export function inBounds(lng: number, lat: number, b: Bounds): boolean {
  return lng >= b[0] && lng <= b[2] && lat >= b[1] && lat <= b[3];
}
