// The Live map (migration 0242): the map library, the basemap and the area it frames. Everything is served by the site
// itself (web/public): MapLibre GL JS, the Natural Earth basemap (scripts/live-map/basemap.mjs) and the label font, so
// the map looks the same with or without internet and needs no tile service, key or change to the security policy.
// No imports: the Worker entry bundles this file.

/** MapLibre GL JS 4.7.1 (BSD-3-Clause), its build for a strict content security policy, and its worker, from /vendor. */
export const MAPLIBRE_VERSION = '4.7.1';
const VENDOR = `/vendor/maplibre-gl-${MAPLIBRE_VERSION}`;
export const MAPLIBRE_JS = `${VENDOR}/maplibre-gl-csp.js`;
export const MAPLIBRE_WORKER = `${VENDOR}/maplibre-gl-csp-worker.js`;
export const MAPLIBRE_CSS = `${VENDOR}/maplibre-gl.css`;
/** Water, the 400-series highways and the city labels (Natural Earth, public domain); Noto Sans for the labels (OFL). */
export const BASEMAP = '/live-map/basemap.geojson';
/** The GTA's highways (401, 404, 410, 427, QEW, DVP, Gardiner, 400, 403, 407), simplified by hand (scripts/live-map/highways.mjs). */
export const HIGHWAYS = '/live-map/highways.geojson';
export const GLYPHS = '/live-map/fonts/{fontstack}/{range}.pbf';
export const MAP_ATTRIBUTION = 'Basemap: Natural Earth. GTA highways: CarmaCars';

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
/** An event this recent shows in the feed as new (and its pin ripples once when it arrives). */
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
