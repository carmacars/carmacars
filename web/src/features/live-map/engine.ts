// The Live map's drawing (migration 0242), outside React. MapLibre GL JS draws the site's own basemap (Natural Earth
// water, the major highways, a dozen city labels with collision handling) and the leads as small glowing dots, clustered
// into a count where they crowd; a hot lead is larger with a soft halo, a visitor on the site breathes slowly, and a new
// event sends one ripple out from its dot. The fleet's cars (once trackers report) are photo markers that glide to each
// new position. Release 25: the GTA's highways by hand (401, 404, 410, 427, QEW, DVP, Gardiner), and the city labels keep
// clear of the photo pins, home base and the cars. Release 26: the land carries the map (regions, a glow where people
// live, the ridges, a quiet lake), the view fits the pins inside the room the TV's header and filmstrip leave, and photo
// pins that would cover each other fan out with a fine line back to their spot. Everything comes from this site
// (config.ts), so it draws the same offline.
import { CAR_SILHOUETTE, arc, clusterPins, separate, spiderOffsets, splitZoom, type Box, type Cluster, type ClusterIn } from './model';
import { BASEMAP, FRAME_MAX_ZOOM, GLYPHS, HIGHWAYS, HOME_BOUNDS, MAPLIBRE_CSS, MAPLIBRE_JS, MAPLIBRE_WORKER, MAP_ATTRIBUTION, MAX_BOUNDS, REGIONS, type Bounds } from './config';

export interface PinSpec { id: string; lng: number; lat: number; colour: string; stage: string; hot: boolean; live: boolean; fresh: boolean; label: string;
  /** Release 26: the name on the pin (first name and last initial, or "Visitor in Toronto"); `known` puts real names first */
  who: string; known: boolean;
  /** Release 27: a lead (not someone renting) and its score: names show only for leads and hot visitors; a bubble takes the hottest member's colour */
  lead: boolean; score: number;
  /** A photo pin (on rent, booked or hot): the car's thumbnail, else the make's initial in the ring; `route` draws its delivery arc from home base. */
  photo?: { src: string | null; initial: string; route: boolean } }
export interface CarSpec { id: string; lng: number; lat: number; colour: string; heading: number | null; label: string; photo: string | null }
export interface Spot { x: number; y: number; w: number; h: number; bw: number; bh: number }
export interface EngineEvents { select(id: string | null, at: Spot | null): void; hover(id: string | null, at: Spot | null): void; moved(): void;
  /** Fleet tracking (0400): a car marker was pressed. */ car?(id: string): void }
/** Pixels the view keeps clear on each side (what sits over the map: the TV's header and filmstrip, the page's layer chips). */
export interface Pad { top: number; right: number; bottom: number; left: number }

/* eslint-disable @typescript-eslint/no-explicit-any -- MapLibre is loaded at run time from /vendor; its types are not installed */
type Ml = any;
type MlMap = any;
type MlMarker = any;

let loading: Promise<Ml | null> | null = null;
/** MapLibre from this site, once per page; null when it cannot load or the browser has no WebGL. */
export function loadMapLibre(): Promise<Ml | null> {
  const w = window as unknown as { maplibregl?: Ml };
  if (w.maplibregl) return Promise.resolve(w.maplibregl);
  loading ??= new Promise<Ml | null>((resolve) => {
    if (!document.querySelector(`link[href="${MAPLIBRE_CSS}"]`)) {
      const css = document.createElement('link');
      css.rel = 'stylesheet'; css.href = MAPLIBRE_CSS;
      document.head.appendChild(css);
    }
    const s = document.createElement('script');
    s.src = MAPLIBRE_JS; s.async = true;
    s.onload = () => {
      const m = w.maplibregl;
      if (!m) return resolve(null);
      m.setWorkerUrl?.(MAPLIBRE_WORKER);
      resolve(!m.supported || m.supported() ? m : null);
    };
    s.onerror = () => resolve(null);
    document.head.appendChild(s);
  }).then((m) => { if (!m) loading = null; return m; });
  return loading;
}

const EMPTY = { type: 'FeatureCollection', features: [] as unknown[] };
/** A 4 px transparent square: scaled to each blocker's size (icon-size is a multiple of it). */
const BLOCK_ICON = 'lm-block';
const BLOCK_PX = 4;
/** The same for a photo pin's landscape card (6 by 4 px, the card's shape), so a city label can sit just under it. */
const BLOCK_CARD = 'lm-block-card';
/** Names by the dots show from this zoom (about city level) up. */
export const NAME_ZOOM = 10.5;
/** The pixels within which pins gather into a count, and the zoom from which they never do. */
export const CLUSTER_UNTIL = 12.5;
const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

export class MapEngine {
  mode: 'loading' | 'map' | 'nogl' = 'loading';
  private ml: Ml | null = null;
  private map: MlMap | null = null;
  private cars = new Map<string, { el: HTMLDivElement; marker: MlMarker; lng: number; lat: number; anim: number }>();
  private photos = new Map<string, { el: HTMLDivElement; marker: MlMarker; key: string; w: number; h: number; lng: number; lat: number; colour: string }>();
  private hq: { marker: MlMarker; key: string } | null = null;
  private hqAt: [number, number] | null = null;
  private dash = 0;
  private where = new Map<string, [number, number]>();
  private seen: Set<string> | null = null;
  private lastPins: PinSpec[] = [];
  /** Release 27: the bubbles drawn now (by key), and the bubble opened on the spot (its members round its middle) */
  private bubbles = new Map<string, Cluster>();
  private spider: { ids: string[]; at: [number, number]; zoom: number } | null = null;
  private lastCars: CarSpec[] = [];
  private selCar: string | null = null;
  private trail: Array<[number, number]> | null = null;
  private zone: Array<[number, number]> | null = null;
  private pinsKey = '';
  private fitKey = '';
  private framed = false;
  private lastFrame: [Bounds, Bounds, Pad] | null = null;
  private back: ReturnType<typeof setTimeout> | undefined;
  /** On the page, once the user moved the map (or a lead was shown on it), new pins no longer re-fit it: it stays where they put it. */
  private held = false;
  private breath = 0;
  private ripple = 0;
  private dead = false;

  /** `scale`: the size of a pixel on this screen (1 at 1080 lines, 2 at 2160), so dots and labels keep their size across the room. */
  constructor(private box: HTMLElement, private ev: EngineEvents, private o: { tv: boolean; scale: number }) {}

  async start(): Promise<'map' | 'nogl'> {
    const ml = await loadMapLibre();
    if (this.dead) return 'nogl';
    if (ml) {
      try {
        const map = new ml.Map({
          container: this.box, style: this.style(), bounds: [[HOME_BOUNDS[0], HOME_BOUNDS[1]], [HOME_BOUNDS[2], HOME_BOUNDS[3]]],
          maxBounds: [[MAX_BOUNDS[0], MAX_BOUNDS[1]], [MAX_BOUNDS[2], MAX_BOUNDS[3]]], fitBoundsOptions: { padding: 24 * this.o.scale, maxZoom: FRAME_MAX_ZOOM },
          attributionControl: false, dragRotate: false, pitchWithRotate: false, touchPitch: false, minZoom: 5.5, maxZoom: 14, fadeDuration: 0,
          // Release 26: a TV's leads open their card on a click, so the map listens; it still never pans or zooms by hand
          ...(this.o.tv ? { dragPan: false, scrollZoom: false, boxZoom: false, doubleClickZoom: false, keyboard: false, touchZoomRotate: false } : {})
        });
        map.addControl(new ml.AttributionControl({ compact: true, customAttribution: MAP_ATTRIBUTION }), 'bottom-right');
        // the credits start folded behind their (i) button (MapLibre opens them at first), so they never cover the map
        const foldCredits = () => this.box.querySelector('.maplibregl-ctrl-attrib.maplibregl-compact-show')?.classList.remove('maplibregl-compact-show');
        map.once('load', foldCredits); map.once('idle', foldCredits);
        if (!this.o.tv) map.addControl(new ml.NavigationControl({ showCompass: false }), 'top-right');
        // the last problem MapLibre met (a file that did not load), for whoever looks at the page
        map.on('error', (e: any) => { this.box.dataset.error = String(e?.error?.message ?? e?.error ?? 'error').slice(0, 200); });
        const ok = await new Promise<boolean>((resolve) => {
          const t = setTimeout(() => resolve(false), 20_000);
          map.once('load', () => { clearTimeout(t); resolve(true); });
        });
        if (this.dead) { map.remove(); return 'nogl'; }
        if (ok) {
          this.ml = ml; this.map = map; this.mode = 'map';
          if (!map.hasImage(BLOCK_ICON)) map.addImage(BLOCK_ICON, { width: BLOCK_PX, height: BLOCK_PX, data: new Uint8Array(BLOCK_PX * BLOCK_PX * 4) });
          if (!map.hasImage(BLOCK_CARD)) map.addImage(BLOCK_CARD, { width: 6, height: 4, data: new Uint8Array(6 * 4 * 4) });
          this.wire();
          this.render();
          this.animate();
          this.animateArcs();
          return 'map';
        }
        map.remove();
      } catch { /* no WebGL */ }
    }
    this.mode = 'nogl';
    return 'nogl';
  }

  destroy() {
    this.dead = true;
    cancelAnimationFrame(this.breath); cancelAnimationFrame(this.ripple); cancelAnimationFrame(this.dash); clearTimeout(this.back);
    for (const c of this.cars.values()) cancelAnimationFrame(c.anim);
    this.map?.remove();
  }

  /** 1068: where a place is on screen (CSS pixels in the map's box), for the booking celebration's pulse. */
  screenOf(lng: number, lat: number): { x: number; y: number } | null { if (!this.map) return null; const p = this.map.project([lng, lat]); return { x: p.x, y: p.y }; }
  setPins(p: PinSpec[]) { this.lastPins = p; if (this.map) this.syncPins(); }
  setCars(c: CarSpec[]) { this.lastCars = c; if (this.map) this.syncCars(); }
  /** Home base (the delivery origin of Program settings): a branded marker with a soft pulse, and where the arcs start. */
  setHq(at: { lat: number; lng: number } | null) { this.hqAt = at ? [at.lng, at.lat] : null; if (this.map) { this.syncHq(); this.syncPins(true); } }

  /** Fleet tracking (0400): a trip's route as a line under the cars (null: none). */
  setTrail(path: Array<[number, number]> | null) { this.trail = path && path.length > 1 ? path : null; if (this.map) this.syncLines(); }
  /** Fleet tracking (0400): the geofence, a ring of points (null: none). */
  setZone(ring: Array<[number, number]> | null) { this.zone = ring; if (this.map) this.syncLines(); }
  /** Fleet tracking (0400): the chosen car's ring stands out. */
  selectCar(id: string | null) { this.selCar = id; for (const [k, v] of this.cars) v.el.classList.toggle('lm-car--sel', k === id); }
  /** The map's box changed size (a layout that settles after the map started). */
  resize() { this.map?.resize(); }
  /** Moves the map to a point (a car or an alert). */
  flyTo(lng: number, lat: number, zoom = 12) { this.map?.easeTo({ center: [lng, lat], zoom: Math.max(this.map.getZoom(), zoom), duration: 700 }); }

  /** Frames `home` (the owner's box) edge to edge inside what `pad` leaves clear, never closer than a city
   * (FRAME_MAX_ZOOM). When a pin would then sit under the UI (a photo pin's half size counts), it frames `all` (the box
   * and every pin, config.frameBounds) instead, with that half size added. Only when something changed. */
  frame(home: Bounds, all: Bounds, pad: Pad) {
    if (!this.map) return;
    this.lastFrame = [home, all, pad];
    if (this.held && !this.o.tv) return;
    const k = this.o.scale, half = this.pinSize(false).h / 2 + 6 * k;
    const w = this.box.clientWidth, h = this.box.clientHeight;
    const fit = (p: Pad): Pad => {
      // a screen too small for the padding: keep a little room in the middle rather than fail
      const q = { ...p };
      if (q.left + q.right > w - 80) { const f = (w - 80) / (q.left + q.right); q.left *= f; q.right *= f; }
      if (q.top + q.bottom > h - 80) { const f = (h - 80) / (q.top + q.bottom); q.top *= f; q.bottom *= f; }
      return q;
    };
    const p0 = fit(pad), p1 = fit({ top: pad.top + half, right: pad.right + half, bottom: pad.bottom + half, left: pad.left + half });
    // does every pin (all's corners) land inside the safe area when the box alone is framed?
    const cam = this.map.cameraForBounds([[home[0], home[1]], [home[2], home[3]]], { padding: p0, maxZoom: FRAME_MAX_ZOOM });
    let use: { b: Bounds; p: Pad } = { b: home, p: p0 };
    if (cam) {
      const scale = 512 * 2 ** cam.zoom, c = this.ml.MercatorCoordinate.fromLngLat(cam.center);
      const px = (lng: number, lat: number): [number, number] => { const m = this.ml.MercatorCoordinate.fromLngLat([lng, lat]); return [w / 2 + (m.x - c.x) * scale, h / 2 + (m.y - c.y) * scale]; };
      const [x0, y0] = px(all[0], all[3]), [x1, y1] = px(all[2], all[1]);
      if (x0 < p1.left || y0 < p1.top || x1 > w - p1.right || y1 > h - p1.bottom) use = { b: all, p: p1 };
    }
    const key = [...use.b.map((x) => x.toFixed(3)), ...Object.values(use.p).map((x) => Math.round(x)), w, h].join(',');
    if (key === this.fitKey) return;
    this.fitKey = key;
    this.box.dataset.frame = use.b === home ? 'home' : 'pins';
    this.map.fitBounds([[use.b[0], use.b[1]], [use.b[2], use.b[3]]], { padding: use.p, duration: this.framed && !reduced() ? 2400 : 0, maxZoom: FRAME_MAX_ZOOM, essential: false });
    this.framed = true;
  }

  /** Back to the frame (after a card closes or a cluster was opened on a TV): the same view as before. */
  reframe() {
    this.held = false;
    if (!this.lastFrame || !this.map) return;
    const [home, all, pad] = this.lastFrame;
    this.fitKey = '';
    this.frame(home, all, pad);
  }

  /** Shows one lead: the map moves to it (out of its cluster) and its card opens. */
  focus(id: string) {
    const at = this.where.get(id);
    if (!at || !this.map) return;
    this.held = true;
    this.map.once('moveend', () => this.ev.select(id, this.spotAt(at)));
    this.map.easeTo({ center: at, zoom: Math.max(this.map.getZoom(), 11.5), duration: 700 });
  }

  // ---------------------------------------------------------------- the style: the site's own basemap
  // Release 26: the land carries the map. The GTA's municipalities a shade lighter than the land round them, a soft glow
  // where people live and where the leads are, the two ridges as gentle relief, the region and municipal borders, all
  // under a near-black, quiet lake; then the highways, the labels and the pins.
  private style() {
    const k = this.o.scale;
    const z = (a: number, b: number) => ['interpolate', ['linear'], ['zoom'], 7, a * k, 11, b * k];
    return {
      version: 8, glyphs: GLYPHS,
      sources: {
        base: { type: 'geojson', data: BASEMAP, attribution: '' },
        land: { type: 'geojson', data: REGIONS, attribution: '' },
        hwy: { type: 'geojson', data: HIGHWAYS, attribution: '' },
        // where the photo pins, home base and the fleet's cars sit: invisible, so the labels make room for them (Release 25)
        blockers: { type: 'geojson', data: EMPTY },
        // a photo pin moved aside to make room: a fine line back to its spot (Release 26)
        leaders: { type: 'geojson', data: EMPTY },
        // Release 27: the pins are clustered by model.clusterPins (the same on the Canvas map), so this source holds the lone pins
        pins: { type: 'geojson', data: EMPTY },
        clusters: { type: 'geojson', data: EMPTY },
        spider: { type: 'geojson', data: EMPTY },
        ripples: { type: 'geojson', data: EMPTY },
        heat: { type: 'geojson', data: EMPTY },
        arcs: { type: 'geojson', data: EMPTY, lineMetrics: true },
        // Fleet tracking (0400): a trip's route and the geofence
        trail: { type: 'geojson', data: EMPTY },
        zone: { type: 'geojson', data: EMPTY }
      },
      layers: [
        // the land round the GTA: a deep slate; the GTA's municipalities a shade lighter, so the region reads at a glance
        { id: 'land', type: 'background', paint: { 'background-color': '#11161f' } },
        { id: 'gta', type: 'fill', source: 'land', filter: ['==', ['get', 'k'], 'muni'], paint: { 'fill-color': '#161d29', 'fill-antialias': false } },
        // where people live: a soft cool light, warmer where the city is densest (under everything, never a hard edge)
        { id: 'glow', type: 'heatmap', source: 'land', filter: ['==', ['get', 'k'], 'glow'], paint: {
          'heatmap-weight': ['get', 'w'], 'heatmap-intensity': ['interpolate', ['linear'], ['zoom'], 7, 0.5, 11, 0.25],
          'heatmap-radius': ['interpolate', ['exponential', 2], ['zoom'], 7, 12 * k, 11, 170 * k], 'heatmap-opacity': 0.9,
          'heatmap-color': ['interpolate', ['linear'], ['heatmap-density'], 0, 'rgba(40,52,74,0)', 0.2, 'rgba(46,62,92,0.35)', 0.5, 'rgba(66,86,124,0.45)', 0.8, 'rgba(120,124,150,0.45)', 1, 'rgba(170,150,130,0.5)'] } },
        // the relief: the Niagara Escarpment and the Oak Ridges Moraine as a wide soft rise with a faint crest
        { id: 'ridge', type: 'line', source: 'land', filter: ['==', ['get', 'k'], 'ridge'], layout: { 'line-join': 'round', 'line-cap': 'round' },
          paint: { 'line-color': '#2f3a50', 'line-width': z(30, 64), 'line-blur': z(26, 54), 'line-opacity': 0.8 } },
        { id: 'ridge-crest', type: 'line', source: 'land', filter: ['==', ['get', 'k'], 'ridge'], layout: { 'line-join': 'round', 'line-cap': 'round' },
          paint: { 'line-color': '#55648a', 'line-width': z(1.2, 2), 'line-blur': z(1.5, 2), 'line-opacity': 0.45, 'line-offset': z(-3, -6) } },
        // where the leads are: a soft cyan to violet bloom on the land
        { id: 'heat', type: 'heatmap', source: 'heat', maxzoom: 13, paint: {
          'heatmap-weight': ['get', 'w'], 'heatmap-intensity': ['interpolate', ['linear'], ['zoom'], 6, 0.6, 11, 1.2],
          'heatmap-radius': ['interpolate', ['linear'], ['zoom'], 6, 26 * k, 11, 60 * k], 'heatmap-opacity': 0.55,
          'heatmap-color': ['interpolate', ['linear'], ['heatmap-density'], 0, 'rgba(34,211,238,0)', 0.25, 'rgba(34,211,238,0.22)', 0.6, 'rgba(99,102,241,0.38)', 1, 'rgba(168,85,247,0.5)'] } },
        // the borders: municipalities a fine dotted line, the regions a clear soft line
        { id: 'border-muni', type: 'line', source: 'land', filter: ['all', ['==', ['get', 'k'], 'border'], ['==', ['get', 'lvl'], 'muni']], layout: { 'line-join': 'round' },
          paint: { 'line-color': '#45526b', 'line-width': z(0.8, 1.1), 'line-opacity': 0.8, 'line-dasharray': [2, 2] } },
        { id: 'border-glow', type: 'line', source: 'land', filter: ['all', ['==', ['get', 'k'], 'border'], ['==', ['get', 'lvl'], 'region']], layout: { 'line-join': 'round' },
          paint: { 'line-color': '#5b6f96', 'line-width': z(5, 8), 'line-blur': z(4, 7), 'line-opacity': 0.16 } },
        { id: 'border', type: 'line', source: 'land', filter: ['all', ['==', ['get', 'k'], 'border'], ['==', ['get', 'lvl'], 'region']], layout: { 'line-join': 'round' },
          paint: { 'line-color': '#55678a', 'line-width': z(1.1, 1.6), 'line-opacity': 0.8 } },
        // the water: near black and still, with one fine line along the shore; it covers the glow, so the light stays on land
        { id: 'water', type: 'fill', source: 'base', filter: ['==', ['get', 'k'], 'water'], paint: { 'fill-color': '#07090e', 'fill-antialias': true } },
        { id: 'shore-glow', type: 'line', source: 'base', filter: ['==', ['get', 'k'], 'water'], paint: { 'line-color': '#24344d', 'line-width': 4 * k, 'line-blur': 4 * k, 'line-opacity': 0.5 } },
        { id: 'shore', type: 'line', source: 'base', filter: ['==', ['get', 'k'], 'water'], paint: { 'line-color': '#334560', 'line-width': 0.9 * k, 'line-opacity': 0.85 } },
        // highways: fine warm lines with a faint glow, a city at night
        { id: 'roads', type: 'line', source: 'base', filter: ['==', ['get', 'k'], 'road'], layout: { 'line-join': 'round', 'line-cap': 'round' },
          paint: { 'line-color': '#6e5a3c', 'line-width': z(0.7, 1.1), 'line-opacity': 0.5 } },
        // the major arterials (Release 26): fine cool grey lines under the highways, the city's grid at night
        { id: 'arterial', type: 'line', source: 'land', filter: ['==', ['get', 'k'], 'arterial'], layout: { 'line-join': 'round', 'line-cap': 'round' },
          paint: { 'line-color': '#5d6a82', 'line-width': z(0.7, 1.3), 'line-opacity': ['interpolate', ['linear'], ['zoom'], 7, 0.45, 10, 0.7] } },
        // the GTA's highways (Release 25): the same faint amber; the parkways a little thinner and darker
        { id: 'hwy-glow', type: 'line', source: 'hwy', layout: { 'line-join': 'round', 'line-cap': 'round' },
          paint: { 'line-color': '#f59e0b', 'line-width': z(5, 8), 'line-blur': z(4, 6), 'line-opacity': 0.07 } },
        { id: 'hwy', type: 'line', source: 'hwy', layout: { 'line-join': 'round', 'line-cap': 'round' },
          paint: { 'line-color': ['match', ['get', 'kind'], 'parkway', '#7a6646', '#9a7a4e'],
            'line-width': ['interpolate', ['linear'], ['zoom'], 7, ['match', ['get', 'kind'], 'parkway', 0.7 * k, 1 * k], 11, ['match', ['get', 'kind'], 'parkway', 1.3 * k, 1.8 * k]],
            'line-opacity': 0.7 } },
        // the regions' names: large, faint and widely spaced, under everything else that is written
        { id: 'region-label', type: 'symbol', source: 'land', filter: ['==', ['get', 'k'], 'region'],
          layout: { 'text-field': ['upcase', ['get', 'name']], 'text-font': ['noto-medium'], 'text-size': 13 * k, 'text-letter-spacing': 0.5, 'text-allow-overlap': false, 'text-padding': 6 * k },
          paint: { 'text-color': '#4d5b78', 'text-opacity': 0.75 } },
        { id: 'ridge-label', type: 'symbol', source: 'land', filter: ['==', ['get', 'k'], 'ridge'], minzoom: 7.6,
          layout: { 'symbol-placement': 'line', 'symbol-spacing': 900 * k, 'text-field': ['upcase', ['get', 'name']], 'text-font': ['noto-regular'], 'text-size': 10 * k,
            'text-letter-spacing': 0.45, 'text-offset': [0, -1.2], 'text-padding': 10 * k, 'text-max-angle': 25 },
          paint: { 'text-color': '#56637d', 'text-opacity': 0.7 } },
        // the geofence (Fleet tracking): a faint fill and a dashed edge; a trip's route: a cyan line with a soft glow
        { id: 'zone-fill', type: 'fill', source: 'zone', paint: { 'fill-color': '#22d3ee', 'fill-opacity': 0.04 } },
        { id: 'zone-edge', type: 'line', source: 'zone', paint: { 'line-color': '#22d3ee', 'line-width': 1.2 * k, 'line-opacity': 0.5, 'line-dasharray': [3, 3] } },
        { id: 'trail-glow', type: 'line', source: 'trail', layout: { 'line-join': 'round', 'line-cap': 'round' }, paint: { 'line-color': '#22d3ee', 'line-width': 8 * k, 'line-blur': 6 * k, 'line-opacity': 0.35 } },
        { id: 'trail', type: 'line', source: 'trail', layout: { 'line-join': 'round', 'line-cap': 'round' }, paint: { 'line-color': '#a5f3fc', 'line-width': 2.4 * k } },
        // the delivery arcs from home base: a faint gradient line, and a dash travelling along it
        { id: 'arc', type: 'line', source: 'arcs', layout: { 'line-cap': 'round' }, paint: { 'line-width': 1.4 * k,
          'line-gradient': ['interpolate', ['linear'], ['line-progress'], 0, 'rgba(250,250,250,0.05)', 1, 'rgba(52,211,153,0.6)'] } },
        { id: 'arc-dash', type: 'line', source: 'arcs', layout: { 'line-cap': 'round' }, paint: { 'line-color': '#a7f3d0', 'line-width': 1.6 * k, 'line-opacity': 0.75, 'line-dasharray': [0, 4, 3] } },
        // a photo pin's way back to its spot: a fine line and a small dot where it belongs
        { id: 'leader', type: 'line', source: 'leaders', filter: ['==', ['geometry-type'], 'LineString'], layout: { 'line-cap': 'round' },
          paint: { 'line-color': ['get', 'colour'], 'line-width': 1.2 * k, 'line-opacity': 0.55 } },
        { id: 'leader-dot', type: 'circle', source: 'leaders', filter: ['==', ['geometry-type'], 'Point'],
          paint: { 'circle-color': ['get', 'colour'], 'circle-radius': 3 * k, 'circle-stroke-color': '#07090e', 'circle-stroke-width': 1.2 * k } },
        // the dots: a soft glow under each, the dot (a little smaller at city zoom, Release 27)
        { id: 'spider-line', type: 'line', source: 'spider', paint: { 'line-color': '#8b98ae', 'line-width': 1 * k, 'line-opacity': 0.6 } },
        { id: 'pin-glow', type: 'circle', source: 'pins',
          paint: { 'circle-color': ['get', 'colour'], 'circle-radius': ['interpolate', ['linear'], ['zoom'], 8, ['case', ['==', ['get', 'hot'], 1], 11 * k, 7.5 * k], 12, ['case', ['==', ['get', 'hot'], 1], 16 * k, 11 * k]],
            'circle-blur': 1, 'circle-opacity': ['case', ['==', ['get', 'hot'], 1], 0.55, 0.4] } },
        { id: 'pin-breath', type: 'circle', source: 'pins', filter: ['==', ['get', 'live'], 1],
          paint: { 'circle-color': '#22d3ee', 'circle-radius': 9 * k, 'circle-blur': 0.9, 'circle-opacity': 0.3 } },
        { id: 'pin', type: 'circle', source: 'pins',
          paint: { 'circle-color': ['get', 'colour'],
            'circle-radius': ['interpolate', ['linear'], ['zoom'], 8, ['case', ['==', ['get', 'hot'], 1], 5.2 * k, 4 * k], 12, ['case', ['==', ['get', 'hot'], 1], 7 * k, 5.5 * k]],
            'circle-stroke-color': '#07090e', 'circle-stroke-width': 1.5 * k } },
        // the names by the dots (Release 27): only for leads and hot visitors, from city zoom up, the hottest first, a name with no room waits
        { id: 'pin-name', type: 'symbol', source: 'pins', filter: ['==', ['get', 'named'], 1], minzoom: NAME_ZOOM,
          layout: { 'text-field': ['get', 'who'], 'text-font': ['noto-medium'], 'text-size': 11 * k, 'text-anchor': 'left', 'text-offset': [0.9, 0],
            'symbol-sort-key': ['-', 3, ['+', ['*', ['get', 'hot'], 2], ['get', 'known']]], 'text-optional': true, 'text-padding': 4 * k, 'text-allow-overlap': false },
          paint: { 'text-color': '#dbe4f3', 'text-halo-color': '#0b0e14', 'text-halo-width': 1.6 * k, 'text-opacity': ['case', ['==', ['get', 'known'], 1], 0.95, 0.7] } },
        // the labels, over the dots and under the clusters: a highway's number along its line (only closer in, and only where
        // nothing else is), then the towns and the cities, each on whichever side of its spot is free
        { id: 'hwy-label', type: 'symbol', source: 'hwy', minzoom: 8.6,
          layout: { 'symbol-placement': 'line', 'symbol-spacing': 420 * k, 'text-field': ['get', 'ref'], 'text-font': ['noto-medium'], 'text-size': 10 * k,
            'text-letter-spacing': 0.08, 'text-padding': 8 * k, 'text-allow-overlap': false },
          paint: { 'text-color': '#8a7656', 'text-halo-color': '#0f131a', 'text-halo-width': 2 * k, 'text-opacity': 0.85 } },
        { id: 'cities', type: 'symbol', source: 'base', filter: ['==', ['get', 'k'], 'city'],
          layout: { 'text-field': ['get', 'name'], 'text-font': ['noto-medium'], 'text-size': ['match', ['get', 'rank'], 1, 17 * k, 2, 13.5 * k, 12.5 * k], 'symbol-sort-key': ['get', 'rank'],
            // far enough out to clear a photo pin on the city's spot (a home-city lead sits exactly there)
            'text-variable-anchor': ['top', 'bottom', 'left', 'right', 'top-left', 'bottom-left', 'top-right', 'bottom-right'], 'text-radial-offset': this.o.tv ? 2.9 : 2.4,
            'text-justify': 'auto', 'text-letter-spacing': 0.2, 'text-max-width': 30, 'text-transform': 'uppercase', 'text-allow-overlap': false, 'text-padding': 4 * k },
          paint: { 'text-color': ['match', ['get', 'rank'], 1, '#c3cee0', '#93a1b8'], 'text-halo-color': '#0b0e14', 'text-halo-width': 1.6 * k, 'text-halo-blur': 1 * k } },
        // the owner's GTA cities (rank 3) as large as the basemap's smaller cities; the towns (rank 4) smaller and quieter
        { id: 'towns', type: 'symbol', source: 'land', filter: ['==', ['get', 'k'], 'town'], minzoom: 7,
          layout: { 'text-field': ['get', 'name'], 'text-font': ['match', ['get', 'rank'], 3, ['literal', ['noto-medium']], ['literal', ['noto-regular']]],
            'text-size': ['match', ['get', 'rank'], 3, 12 * k, 10.5 * k], 'symbol-sort-key': ['get', 'rank'],
            'text-variable-anchor': ['top', 'bottom', 'left', 'right', 'center'], 'text-radial-offset': this.o.tv ? 2.6 : 2.2, 'text-letter-spacing': 0.16, 'text-transform': 'uppercase',
            'text-allow-overlap': false, 'text-padding': 4 * k },
          paint: { 'text-color': ['match', ['get', 'rank'], 3, '#8f9cb3', '#647189'], 'text-halo-color': '#0b0e14', 'text-halo-width': 1.4 * k } },
        { id: 'cluster-glow', type: 'circle', source: 'clusters',
          paint: { 'circle-color': ['get', 'colour'], 'circle-radius': ['step', ['get', 'n'], 22 * k, 10, 28 * k, 40, 34 * k], 'circle-blur': 1, 'circle-opacity': ['case', ['==', ['get', 'hot'], 1], 0.55, 0.35] } },
        { id: 'cluster', type: 'circle', source: 'clusters',
          paint: { 'circle-color': '#0f1624', 'circle-radius': ['step', ['get', 'n'], 13 * k, 10, 16 * k, 40, 19 * k],
            'circle-stroke-color': ['get', 'colour'], 'circle-stroke-width': ['case', ['==', ['get', 'hot'], 1], 3 * k, 2 * k] } },
        { id: 'cluster-n', type: 'symbol', source: 'clusters',
          // always drawn, and the labels keep clear of the bubble (the padding is about the size of a small one)
          layout: { 'text-field': ['get', 'label'], 'text-font': ['noto-medium'], 'text-size': 13 * k, 'text-allow-overlap': true, 'text-ignore-placement': false,
            'text-padding': 10 * k },
          paint: { 'text-color': '#e8eef8' } },
        { id: 'ripple', type: 'circle', source: 'ripples', paint: { 'circle-color': 'rgba(0,0,0,0)', 'circle-radius': 6 * k, 'circle-stroke-color': '#22d3ee', 'circle-stroke-width': 2 * k, 'circle-stroke-opacity': 0 } },
        // on top, so placed first: a transparent box the size of each photo pin, home base and car (drawn as page
        // elements above the map, which the labels cannot see), so a city label moves to a free side or waits
        { id: 'pin-block', type: 'symbol', source: 'blockers',
          layout: { 'icon-image': ['get', 'i'], 'icon-size': ['get', 's'], 'icon-allow-overlap': true, 'icon-ignore-placement': false, 'icon-padding': 2 * k },
          paint: { 'icon-opacity': 0 } }
      ]
    };
  }
  // ---------------------------------------------------------------- pointer: a dot's card, a cluster opens
  private wire() {
    const map = this.map;
    const at = (e: any): Spot => ({ x: e.point.x - 6, y: e.point.y - 6, w: 12, h: 12, bw: this.box.clientWidth, bh: this.box.clientHeight });
    map.on('mousemove', 'pin', (e: any) => { map.getCanvas().style.cursor = 'pointer'; const id = e.features?.[0]?.properties?.id; if (id) this.ev.hover(String(id), at(e)); });
    map.on('mouseleave', 'pin', () => { map.getCanvas().style.cursor = ''; this.ev.hover(null, null); });
    map.on('click', (e: any) => {
      const f = map.queryRenderedFeatures(e.point, { layers: ['pin', 'cluster'] })[0];
      if (!f) { if (this.spider) { this.spider = null; this.syncPins(true); } return this.ev.select(null, null); }
      if (f.properties?.cluster === 1) { this.open(String(f.properties.key)); return; }
      this.ev.select(String(f.properties.id), at(e));
    });
    map.on('mouseenter', 'cluster', () => { map.getCanvas().style.cursor = 'pointer'; });
    map.on('mouseleave', 'cluster', () => { map.getCanvas().style.cursor = ''; });
    map.on('movestart', (e: any) => { if (e?.originalEvent) this.held = true; this.ev.moved(); });
    // the bubbles regroup when the zoom settles (a bubble splits as you zoom in)
    map.on('zoomend', () => this.syncPins());
    map.on('moveend', () => this.layout());
    map.on('resize', () => this.layout());
  }

  private spotAt(ll: [number, number]): Spot {
    const p = this.map.project(ll);
    return { x: p.x - 6, y: p.y - 6, w: 12, h: 12, bw: this.box.clientWidth, bh: this.box.clientHeight };
  }

  private render() { this.syncHq(); this.syncPins(); this.syncCars(); this.syncLines(); }

  private syncLines() {
    this.map.getSource('trail')?.setData(this.trail ? { type: 'FeatureCollection', features: [{ type: 'Feature', geometry: { type: 'LineString', coordinates: this.trail }, properties: {} }] } : EMPTY);
    this.map.getSource('zone')?.setData(this.zone ? { type: 'FeatureCollection', features: [{ type: 'Feature', geometry: { type: 'Polygon', coordinates: [this.zone] }, properties: {} }] } : EMPTY);
    this.box.dataset.trail = String(this.trail?.length ?? 0);
  }

  /** The pixels within which pins gather into a bubble at this zoom (none from CLUSTER_UNTIL up). */
  private radiusAt = (z: number) => (z >= CLUSTER_UNTIL ? 0 : (z < 10 ? 36 : 30) * this.o.scale);

  /** A bubble was pressed: zoom in to where it splits; when it will not (its pins sit on one spot) open it as a ring. */
  private open(key: string) {
    const c = this.bubbles.get(key);
    if (!c) return;
    this.held = true;
    const members: ClusterIn[] = c.ids.map((id) => this.lastPins.find((p) => p.id === id)).filter((p): p is PinSpec => !!p)
      .map((p) => ({ id: p.id, lng: p.lng, lat: p.lat, hot: p.hot, score: p.score, colour: p.colour }));
    const z = splitZoom(members, this.map.getZoom(), 14, this.radiusAt);
    if (z === null || z > 14) {
      this.spider = { ids: c.ids, at: [c.lng, c.lat], zoom: this.map.getZoom() };
      this.syncPins(true);
    } else {
      this.spider = null;
      this.map.easeTo({ center: [c.lng, c.lat], zoom: Math.min(14, z + 0.2), duration: reduced() ? 0 : 600 });
    }
    // a TV goes back to its frame by itself after 20 seconds
    if (this.o.tv) { clearTimeout(this.back); this.back = setTimeout(() => { this.spider = null; this.reframe(); }, 20_000); }
  }

  private syncPins(force = false) {
    const zoom = this.map.getZoom();
    if (this.spider && Math.abs(this.spider.zoom - zoom) > 0.4) this.spider = null;
    const key = JSON.stringify([this.hqAt, Math.round(zoom * 20), this.spider?.ids.length ?? 0, this.lastPins.map((p) => [p.id, p.lng, p.lat, p.colour, p.hot, p.live, p.lead, p.photo?.src ?? p.photo?.initial ?? ''])]);
    this.where = new Map(this.lastPins.map((p) => [p.id, [p.lng, p.lat] as [number, number]]));
    this.box.dataset.pins = String(this.lastPins.length);
    if (key === this.pinsKey && !force) return;
    this.pinsKey = key;
    // who is alone and who is in a bubble at this zoom; a bubble opened on the spot shows its members round its middle
    const open = new Set(this.spider?.ids ?? []);
    const grouped = clusterPins(this.lastPins.filter((p) => !open.has(p.id)).map((p): ClusterIn => ({ id: p.id, lng: p.lng, lat: p.lat, hot: p.hot, score: p.score, colour: p.colour })),
      512 * 2 ** zoom, this.radiusAt(zoom));
    const alone = new Set(grouped.singles.map((s) => s.id));
    const at = new Map<string, [number, number]>();
    const lines: unknown[] = [];
    if (this.spider) {
      const centre = this.map.project(this.spider.at), offs = spiderOffsets(this.spider.ids.length, 30 * this.o.scale);
      this.spider.ids.forEach((id, i) => {
        const o = offs[i]!, ll = this.map.unproject([centre.x + o[0], centre.y + o[1]]);
        at.set(id, [ll.lng, ll.lat]); alone.add(id);
        lines.push({ type: 'Feature', geometry: { type: 'LineString', coordinates: [this.spider!.at, [ll.lng, ll.lat]] }, properties: {} });
      });
    }
    this.bubbles = new Map(grouped.clusters.map((c) => [c.key, c]));
    const pos = (p: PinSpec): [number, number] => at.get(p.id) ?? [p.lng, p.lat];
    const lone = this.lastPins.filter((p) => alone.has(p.id)).map((p) => ({ ...p, lng: pos(p)[0], lat: pos(p)[1] }));
    const dots = lone.filter((p) => !p.photo), photos = lone.filter((p) => p.photo);
    this.box.dataset.photos = String(photos.length);
    this.box.dataset.clusters = String(grouped.clusters.length);
    this.syncPhotos(photos);
    this.map.getSource('heat').setData({ type: 'FeatureCollection', features: this.lastPins.map((p) => ({
      type: 'Feature', geometry: { type: 'Point', coordinates: [p.lng, p.lat] }, properties: { w: p.hot ? 1 : 0.55 } })) });
    const hq = this.hqAt, routes = hq ? photos.filter((p) => p.photo?.route) : [];
    this.map.getSource('arcs').setData({ type: 'FeatureCollection', features: routes.map((p) => ({
      type: 'Feature', geometry: { type: 'LineString', coordinates: arc(hq!, [p.lng, p.lat]) }, properties: {} })) });
    this.box.dataset.arcs = String(routes.length);
    this.map.getSource('pins').setData({ type: 'FeatureCollection', features: dots.map((p) => ({
      type: 'Feature', geometry: { type: 'Point', coordinates: [p.lng, p.lat] },
      properties: { id: p.id, colour: p.colour, stage: p.stage, hot: p.hot ? 1 : 0, live: p.live ? 1 : 0, who: p.who, known: p.known ? 1 : 0, named: p.hot || (p.lead && p.known) ? 1 : 0 }
    })) });
    this.map.getSource('clusters').setData({ type: 'FeatureCollection', features: grouped.clusters.map((c) => ({
      type: 'Feature', geometry: { type: 'Point', coordinates: [c.lng, c.lat] }, properties: { key: c.key, cluster: 1, n: c.n, label: c.n > 99 ? '99+' : String(c.n), colour: c.colour, hot: c.hot ? 1 : 0 } })) });
    this.map.getSource('spider').setData({ type: 'FeatureCollection', features: lines });
    // a new event since the last refresh: one ripple from its dot (none on the first load)
    const ids = new Set(this.lastPins.map((p) => p.id));
    if (this.seen) {
      const fresh = lone.filter((p) => p.fresh && !this.seen!.has(p.id));
      if (fresh.length) this.rippleOut(fresh);
    }
    this.seen = ids;
  }

  /** Photo pins: the car on a small card framed in its stage colour, above the dots, never clustered. */
  private syncPhotos(list: PinSpec[]) {
    const seen = new Set<string>();
    for (const p of list) {
      seen.add(p.id);
      const sz0 = this.pinSize(p.hot && !p.photo!.route), key = `${p.colour}|${p.photo!.src ?? p.photo!.initial}|${p.hot}|${p.who}|${sz0.w}`;
      let v = this.photos.get(p.id);
      if (!v) {
        const el = document.createElement('div');
        el.className = 'lm-ph';
        el.tabIndex = this.o.tv ? -1 : 0;
        el.setAttribute('role', 'button');
        const id = p.id, spot = (): Spot => { const r = el.getBoundingClientRect(), b = this.box.getBoundingClientRect(); return { x: r.left - b.left, y: r.top - b.top, w: r.width, h: r.height, bw: b.width, bh: b.height }; };
        el.addEventListener('mouseenter', () => this.ev.hover(id, spot()));
        el.addEventListener('mouseleave', () => this.ev.hover(null, null));
        el.addEventListener('focus', () => this.ev.hover(id, spot()));
        el.addEventListener('blur', () => this.ev.hover(null, null));
        el.addEventListener('click', (e) => { e.stopPropagation(); this.ev.select(id, spot()); });
        v = { el, marker: new this.ml.Marker({ element: el, anchor: 'center' }).setLngLat([p.lng, p.lat]).addTo(this.map), key: '', w: 0, h: 0, lng: p.lng, lat: p.lat, colour: p.colour };
        this.photos.set(p.id, v);
      }
      v.marker.setLngLat([p.lng, p.lat]);
      v.lng = p.lng; v.lat = p.lat; v.colour = p.colour;
      v.el.setAttribute('aria-label', p.label);
      if (v.key !== key) {
        v.key = key;
        v.el.style.setProperty('--c', p.colour);
        const sz = this.pinSize(p.hot && !p.photo!.route);
        v.w = sz.w; v.h = sz.h;
        v.el.style.setProperty('--w', `${sz.w}px`);
        v.el.style.setProperty('--h', `${sz.h}px`);
        // the rose ring marks a hot lead still to win; a booked or rented car keeps its stage colour clean
        v.el.classList.toggle('lm-ph--hot', p.hot && !p.photo!.route);
        const ini = p.photo!.initial.replace(/[^A-Z0-9]/g, '');
        v.el.innerHTML = (p.photo!.src ? `<img alt="" src="${encodeURI(p.photo!.src)}" decoding="async">` : ini ? `<span aria-hidden="true">${ini}</span>` : `<span class="lm-ph__shape">${CAR_SILHOUETTE}</span>`)
          // the name along the card's foot (Release 26); text only, never markup from the data
          + '<b class="lm-ph__name" aria-hidden="true"></b>';
        v.el.querySelector('.lm-ph__name')!.textContent = p.who;
      }
    }
    for (const [id, v] of this.photos) if (!seen.has(id)) { v.marker.remove(); this.photos.delete(id); }
    this.layout();
  }

  /** A photo pin's size on screen: a small landscape card (the car is wider than tall); a hot lead's car a little smaller. */
  private pinSize(small: boolean) {
    // a phone's map is small: smaller cards, so the pins do not cover the area they sit in
    // Release 27: a little smaller at city zoom, full size once you are close
    const z = this.map ? this.map.getZoom() : 10, zoomK = z < 10 ? 0.78 : z < 11.5 ? 0.9 : 1;
    const k = this.o.scale * (this.o.tv ? 1 : this.box.clientWidth < 560 ? 0.6 : 0.8) * zoomK, w = (small ? 66 : 80) * k;
    return { w, h: Math.round(w * 0.66) };
  }

  /** Photo pins and home base that would cover each other move apart (model.separate) with a line back to each spot;
   * the labels' keep-out boxes follow where they are drawn. Runs when the view settles and when the pins change. */
  private layout() {
    const map = this.map;
    if (!map) return;
    const boxes: Box[] = [];
    for (const [id, v] of this.photos) { const pt = map.project([v.lng, v.lat]); boxes.push({ id, x: pt.x, y: pt.y, w: v.w, h: v.h }); }
    const hqPx = 30 * this.o.scale;
    if (this.hqAt) { const pt = map.project(this.hqAt); boxes.push({ id: 'home-base', x: pt.x, y: pt.y, w: hqPx, h: hqPx, fixed: true }); }
    const at = separate(boxes, 8 * this.o.scale);
    const leaders: unknown[] = [];
    let moved = 0;
    for (const b of boxes) {
      const v = this.photos.get(b.id), to = at.get(b.id)!;
      if (!v) continue;
      const dx = to.x - b.x, dy = to.y - b.y;
      v.marker.setOffset([dx, dy]);
      if (Math.hypot(dx, dy) > 2) {
        moved++;
        const end = map.unproject([to.x, to.y]);
        leaders.push({ type: 'Feature', geometry: { type: 'LineString', coordinates: [[v.lng, v.lat], [end.lng, end.lat]] }, properties: { colour: v.colour } },
          { type: 'Feature', geometry: { type: 'Point', coordinates: [v.lng, v.lat] }, properties: { colour: v.colour } });
      }
    }
    map.getSource('leaders')?.setData({ type: 'FeatureCollection', features: leaders });
    this.box.dataset.fanned = String(moved);
    this.box.dataset.zoom = map.getZoom().toFixed(2);
    this.syncBlockers(at);
  }

  private syncHq() {
    const at = this.hqAt, key = at ? at.join(',') : '';
    if (this.hq && this.hq.key === key) return;
    this.hq?.marker.remove(); this.hq = null;
    if (!at) return;
    const el = document.createElement('div');
    el.className = 'lm-hq';
    el.setAttribute('role', 'img');
    el.setAttribute('aria-label', 'CarmaCars home base');
    el.style.setProperty('--s', `${30 * this.o.scale}px`);
    el.innerHTML = '<span class="lm-hq__pulse" aria-hidden="true"></span><span class="lm-hq__mark" aria-hidden="true">C</span>';
    this.hq = { marker: new this.ml.Marker({ element: el, anchor: 'center' }).setLngLat(at).addTo(this.map), key };
    this.layout();
  }

  /** The dash travelling along the delivery arcs (MapLibre's dash sequence, about one step every 70 ms). */
  private animateArcs() {
    if (reduced()) return;
    const seq = [[0, 4, 3], [0.5, 4, 2.5], [1, 4, 2], [1.5, 4, 1.5], [2, 4, 1], [2.5, 4, 0.5], [3, 4, 0], [0, 0.5, 3, 3.5], [0, 1, 3, 3], [0, 1.5, 3, 2.5], [0, 2, 3, 2], [0, 2.5, 3, 1.5], [0, 3, 3, 1], [0, 3.5, 3, 0.5]];
    let step = -1, last = 0;
    const tick = (t: number) => {
      if (this.dead || !this.map) return;
      if (t - last > 70) {
        last = t;
        const n = Math.floor(t / 70) % seq.length;
        if (n !== step) { step = n; this.map.setPaintProperty('arc-dash', 'line-dasharray', seq[n]); }
      }
      this.dash = requestAnimationFrame(tick);
    };
    this.dash = requestAnimationFrame(tick);
  }

  private rippleOut(pins: PinSpec[]) {
    const k = this.o.scale, src = this.map.getSource('ripples');
    src.setData({ type: 'FeatureCollection', features: pins.map((p) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: [p.lng, p.lat] }, properties: {} })) });
    if (reduced()) { setTimeout(() => src.setData(EMPTY), 1500); this.map.setPaintProperty('ripple', 'circle-stroke-opacity', 0.6); return; }
    cancelAnimationFrame(this.ripple);
    const t0 = performance.now(), ms = 1800;
    const step = (t: number) => {
      if (this.dead || !this.map) return;
      const f = Math.min(1, (t - t0) / ms), e = 1 - (1 - f) ** 3;
      this.map.setPaintProperty('ripple', 'circle-radius', (6 + 42 * e) * k);
      this.map.setPaintProperty('ripple', 'circle-stroke-opacity', 0.7 * (1 - f));
      if (f < 1) this.ripple = requestAnimationFrame(step); else src.setData(EMPTY);
    };
    this.ripple = requestAnimationFrame(step);
  }

  /** Visitors on the site breathe: a slow glow, about 4 seconds a breath, 12 frames a second. */
  private animate() {
    if (reduced()) return;
    const k = this.o.scale;
    let last = 0;
    const step = (t: number) => {
      if (this.dead || !this.map) return;
      if (t - last > 80) {
        last = t;
        const s = (Math.sin((t / 4000) * Math.PI * 2) + 1) / 2;
        this.map.setPaintProperty('pin-breath', 'circle-radius', (8 + 7 * s) * k);
        this.map.setPaintProperty('pin-breath', 'circle-opacity', 0.12 + 0.3 * s);
      }
      this.breath = requestAnimationFrame(step);
    };
    this.breath = requestAnimationFrame(step);
  }

  // ---------------------------------------------------------------- the fleet (once trackers report)
  private syncCars() {
    const seen = new Set<string>();
    for (const s of this.lastCars) {
      seen.add(s.id);
      let v = this.cars.get(s.id);
      if (!v) {
        const el = document.createElement('div');
        el.className = 'lm-car';
        el.setAttribute('role', 'img');
        el.innerHTML = `<span class="lm-car__arrow" aria-hidden="true"></span><span class="lm-car__body" aria-hidden="true">${s.photo ? `<img alt="" src="${encodeURI(s.photo)}" decoding="async">` : `<span class="lm-car__shape">${CAR_SILHOUETTE}</span>`}</span>`;
        // Fleet tracking (0400): a car can be chosen (a button then, for the keyboard too)
        if (this.ev.car) {
          const id = s.id;
          el.setAttribute('role', 'button'); el.tabIndex = 0; el.classList.add('lm-car--pick');
          el.addEventListener('click', (e) => { e.stopPropagation(); this.ev.car?.(id); });
          el.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); this.ev.car?.(id); } });
        }
        const marker = new this.ml.Marker({ element: el, anchor: 'center' }).setLngLat([s.lng, s.lat]).addTo(this.map);
        v = { el, marker, lng: s.lng, lat: s.lat, anim: 0 };
        this.cars.set(s.id, v);
      }
      v.el.style.setProperty('--c', s.colour);
      v.el.style.setProperty('--h', `${s.heading ?? 0}deg`);
      v.el.classList.toggle('lm-car--still', s.heading === null);
      v.el.classList.toggle('lm-car--sel', s.id === this.selCar);
      v.el.setAttribute('aria-label', s.label);
      if (v.lng !== s.lng || v.lat !== s.lat) this.glide(v, s.lng, s.lat);
    }
    for (const [id, v] of this.cars) if (!seen.has(id)) { cancelAnimationFrame(v.anim); v.marker.remove(); this.cars.delete(id); }
    this.layout();
    this.box.dataset.cars = String(this.lastCars.length);
  }

  /** The labels' keep-out squares: every photo pin (where it is drawn, once moved aside), home base and car, at its size on screen. */
  private syncBlockers(at?: Map<string, { x: number; y: number }>) {
    const src = this.map?.getSource('blockers');
    if (!src) return;
    const k = this.o.scale, f: unknown[] = [];
    const add = (lng: number, lat: number, px: number, card = false) => f.push({ type: 'Feature', geometry: { type: 'Point', coordinates: [lng, lat] },
      properties: card ? { i: BLOCK_CARD, s: px / 6 } : { i: BLOCK_ICON, s: px / BLOCK_PX } });
    for (const [id, v] of this.photos) {
      const to = at?.get(id), ll = to ? this.map.unproject([to.x, to.y]) : { lng: v.lng, lat: v.lat };
      add(ll.lng, ll.lat, v.w, true);
    }
    if (this.hqAt) add(this.hqAt[0], this.hqAt[1], 30 * k);
    for (const c of this.lastCars) add(c.lng, c.lat, 34 * k);
    src.setData({ type: 'FeatureCollection', features: f });
    this.box.dataset.blockers = String(f.length);
  }

  /** A car moves smoothly to its new position over two seconds (at once with reduced motion). */
  private glide(v: { marker: MlMarker; lng: number; lat: number; anim: number }, lng: number, lat: number) {
    cancelAnimationFrame(v.anim);
    const from = { lng: v.lng, lat: v.lat }, t0 = performance.now(), ms = reduced() ? 0 : 2000;
    const step = (t: number) => {
      const k = ms ? Math.min(1, (t - t0) / ms) : 1, e = k < 0.5 ? 2 * k * k : 1 - (-2 * k + 2) ** 2 / 2;
      v.lng = from.lng + (lng - from.lng) * e; v.lat = from.lat + (lat - from.lat) * e;
      v.marker.setLngLat([v.lng, v.lat]);
      if (k < 1) v.anim = requestAnimationFrame(step);
    };
    v.anim = requestAnimationFrame(step);
  }
}
