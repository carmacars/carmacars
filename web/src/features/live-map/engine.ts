// The Live map's drawing (migration 0242), outside React. MapLibre GL JS draws the site's own basemap (Natural Earth
// water, the major highways, a dozen city labels with collision handling) and the leads as small glowing dots, clustered
// into a count where they crowd; a hot lead is larger with a soft halo, a visitor on the site breathes slowly, and a new
// event sends one ripple out from its dot. The fleet's cars (once trackers report) are photo markers that glide to each
// new position. Everything comes from this site (config.ts), so it draws the same offline.
import { BASEMAP, GLYPHS, HOME_BOUNDS, MAPLIBRE_CSS, MAPLIBRE_JS, MAPLIBRE_WORKER, MAP_ATTRIBUTION, MAX_BOUNDS, type Bounds } from './config';

export interface PinSpec { id: string; lng: number; lat: number; colour: string; stage: string; hot: boolean; live: boolean; fresh: boolean; label: string }
export interface CarSpec { id: string; lng: number; lat: number; colour: string; heading: number | null; label: string; photo: string | null }
export interface Spot { x: number; y: number; w: number; h: number; bw: number; bh: number }
export interface EngineEvents { select(id: string | null, at: Spot | null): void; hover(id: string | null, at: Spot | null): void; moved(): void }

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
const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

export class MapEngine {
  mode: 'loading' | 'map' | 'nogl' = 'loading';
  private ml: Ml | null = null;
  private map: MlMap | null = null;
  private cars = new Map<string, { el: HTMLDivElement; marker: MlMarker; lng: number; lat: number; anim: number }>();
  private where = new Map<string, [number, number]>();
  private seen: Set<string> | null = null;
  private lastPins: PinSpec[] = [];
  private lastCars: CarSpec[] = [];
  private pinsKey = '';
  private fitKey = '';
  private framed = false;
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
          maxBounds: [[MAX_BOUNDS[0], MAX_BOUNDS[1]], [MAX_BOUNDS[2], MAX_BOUNDS[3]]], fitBoundsOptions: { padding: 24 * this.o.scale },
          attributionControl: false, dragRotate: false, pitchWithRotate: false, touchPitch: false, minZoom: 5.5, maxZoom: 14, interactive: !this.o.tv, fadeDuration: 0
        });
        map.addControl(new ml.AttributionControl({ compact: true, customAttribution: MAP_ATTRIBUTION }), 'bottom-right');
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
          this.wire();
          this.render();
          this.animate();
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
    cancelAnimationFrame(this.breath); cancelAnimationFrame(this.ripple);
    for (const c of this.cars.values()) cancelAnimationFrame(c.anim);
    this.map?.remove();
  }

  setPins(p: PinSpec[]) { this.lastPins = p; if (this.map) this.syncPins(); }
  setCars(c: CarSpec[]) { this.lastCars = c; if (this.map) this.syncCars(); }

  /** Frames the area, widened to take in the pins drawn (never past southern Ontario); only when that changes. */
  frame(b: Bounds) {
    const key = b.map((x) => x.toFixed(2)).join(',');
    if (key === this.fitKey || !this.map) return;
    this.fitKey = key;
    this.map.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: (this.o.tv ? 40 : 24) * this.o.scale, duration: this.framed ? 900 : 0, maxZoom: 11 });
    this.framed = true;
  }

  /** Shows one lead: the map moves to it (out of its cluster) and its card opens. */
  focus(id: string) {
    const at = this.where.get(id);
    if (!at || !this.map) return;
    this.map.once('moveend', () => this.ev.select(id, this.spotAt(at)));
    this.map.easeTo({ center: at, zoom: Math.max(this.map.getZoom(), 11.5), duration: 700 });
  }

  // ---------------------------------------------------------------- the style: the site's own basemap
  private style() {
    const k = this.o.scale;
    return {
      version: 8, glyphs: GLYPHS,
      sources: {
        base: { type: 'geojson', data: BASEMAP, attribution: '' },
        pins: { type: 'geojson', data: EMPTY, cluster: true, clusterRadius: 26 * k, clusterMaxZoom: 10,
          clusterProperties: { hot: ['max', ['get', 'hot']], live: ['max', ['get', 'live']], booked: ['+', ['case', ['==', ['get', 'stage'], 'booked'], 1, 0]],
            progress: ['+', ['case', ['==', ['get', 'stage'], 'progress'], 1, 0]], site: ['+', ['case', ['==', ['get', 'stage'], 'site'], 1, 0]], past: ['+', ['case', ['==', ['get', 'stage'], 'past'], 1, 0]] } },
        ripples: { type: 'geojson', data: EMPTY }
      },
      layers: [
        { id: 'land', type: 'background', paint: { 'background-color': '#0b0f17' } },
        { id: 'water', type: 'fill', source: 'base', filter: ['==', ['get', 'k'], 'water'], paint: { 'fill-color': '#131c2c' } },
        { id: 'shore', type: 'line', source: 'base', filter: ['==', ['get', 'k'], 'water'], paint: { 'line-color': '#1c2940', 'line-width': 1 * k } },
        { id: 'roads', type: 'line', source: 'base', filter: ['==', ['get', 'k'], 'road'], layout: { 'line-join': 'round', 'line-cap': 'round' },
          paint: { 'line-color': '#26324a', 'line-width': ['interpolate', ['linear'], ['zoom'], 6, 0.6 * k, 10, 1.2 * k], 'line-opacity': 0.85 } },
        { id: 'cities', type: 'symbol', source: 'base', filter: ['==', ['get', 'k'], 'city'],
          layout: { 'text-field': ['get', 'name'], 'text-font': ['noto-medium'], 'text-size': ['match', ['get', 'rank'], 1, 16 * k, 14 * k], 'symbol-sort-key': ['get', 'rank'],
            'text-anchor': 'left', 'text-offset': [1.4, 0], 'text-letter-spacing': 0.06, 'text-transform': 'uppercase', 'text-allow-overlap': false, 'text-padding': 6 * k },
          paint: { 'text-color': '#5d6b84', 'text-halo-color': '#0b0f17', 'text-halo-width': 1.5 * k } },
        // the dots: a soft glow under each, the dot, and the clusters' counts
        { id: 'pin-glow', type: 'circle', source: 'pins', filter: ['!', ['has', 'point_count']],
          paint: { 'circle-color': ['get', 'colour'], 'circle-radius': ['case', ['==', ['get', 'hot'], 1], 16 * k, 10 * k], 'circle-blur': 1, 'circle-opacity': ['case', ['==', ['get', 'hot'], 1], 0.55, 0.35] } },
        { id: 'pin-breath', type: 'circle', source: 'pins', filter: ['all', ['!', ['has', 'point_count']], ['==', ['get', 'live'], 1]],
          paint: { 'circle-color': '#22d3ee', 'circle-radius': 9 * k, 'circle-blur': 0.9, 'circle-opacity': 0.3 } },
        { id: 'pin', type: 'circle', source: 'pins', filter: ['!', ['has', 'point_count']],
          paint: { 'circle-color': ['get', 'colour'], 'circle-radius': ['case', ['==', ['get', 'hot'], 1], 7 * k, 5 * k],
            'circle-stroke-color': '#0b0f17', 'circle-stroke-width': 1.5 * k } },
        { id: 'cluster-glow', type: 'circle', source: 'pins', filter: ['has', 'point_count'],
          paint: { 'circle-color': this.clusterColour(), 'circle-radius': ['step', ['get', 'point_count'], 22 * k, 10, 28 * k, 40, 34 * k], 'circle-blur': 1, 'circle-opacity': 0.35 } },
        { id: 'cluster', type: 'circle', source: 'pins', filter: ['has', 'point_count'],
          paint: { 'circle-color': '#0f1624', 'circle-radius': ['step', ['get', 'point_count'], 13 * k, 10, 16 * k, 40, 19 * k],
            'circle-stroke-color': this.clusterColour(), 'circle-stroke-width': 2 * k } },
        { id: 'cluster-n', type: 'symbol', source: 'pins', filter: ['has', 'point_count'],
          layout: { 'text-field': ['get', 'point_count_abbreviated'], 'text-font': ['noto-medium'], 'text-size': 13 * k, 'text-allow-overlap': true, 'text-ignore-placement': true },
          paint: { 'text-color': '#e8eef8' } },
        { id: 'ripple', type: 'circle', source: 'ripples', paint: { 'circle-color': 'rgba(0,0,0,0)', 'circle-radius': 6 * k, 'circle-stroke-color': '#22d3ee', 'circle-stroke-width': 2 * k, 'circle-stroke-opacity': 0 } }
      ]
    };
  }
  /** A cluster takes the colour of its most advanced stage present. */
  private clusterColour() {
    return ['case', ['>', ['get', 'booked'], 0], '#34d399', ['>', ['get', 'progress'], 0], '#fbbf24', ['>', ['get', 'site'], 0], '#22d3ee', '#94a3b8'];
  }

  // ---------------------------------------------------------------- pointer: a dot's card, a cluster opens
  private wire() {
    const map = this.map;
    const at = (e: any): Spot => ({ x: e.point.x - 6, y: e.point.y - 6, w: 12, h: 12, bw: this.box.clientWidth, bh: this.box.clientHeight });
    map.on('mousemove', 'pin', (e: any) => { map.getCanvas().style.cursor = 'pointer'; const id = e.features?.[0]?.properties?.id; if (id) this.ev.hover(String(id), at(e)); });
    map.on('mouseleave', 'pin', () => { map.getCanvas().style.cursor = ''; this.ev.hover(null, null); });
    map.on('click', (e: any) => {
      const f = map.queryRenderedFeatures(e.point, { layers: ['pin', 'cluster'] })[0];
      if (!f) return this.ev.select(null, null);
      if (f.properties?.cluster_id !== undefined) {
        void map.getSource('pins').getClusterExpansionZoom(f.properties.cluster_id).then((z: number) => map.easeTo({ center: f.geometry.coordinates, zoom: z + 0.2, duration: 600 }));
        return;
      }
      this.ev.select(String(f.properties.id), at(e));
    });
    map.on('mouseenter', 'cluster', () => { map.getCanvas().style.cursor = 'pointer'; });
    map.on('mouseleave', 'cluster', () => { map.getCanvas().style.cursor = ''; });
    map.on('movestart', () => this.ev.moved());
  }

  private spotAt(ll: [number, number]): Spot {
    const p = this.map.project(ll);
    return { x: p.x - 6, y: p.y - 6, w: 12, h: 12, bw: this.box.clientWidth, bh: this.box.clientHeight };
  }

  private render() { this.syncPins(); this.syncCars(); }

  private syncPins() {
    const key = JSON.stringify(this.lastPins.map((p) => [p.id, p.lng, p.lat, p.colour, p.hot, p.live]));
    this.where = new Map(this.lastPins.map((p) => [p.id, [p.lng, p.lat] as [number, number]]));
    this.box.dataset.pins = String(this.lastPins.length);
    if (key === this.pinsKey) return;
    this.pinsKey = key;
    this.map.getSource('pins').setData({ type: 'FeatureCollection', features: this.lastPins.map((p) => ({
      type: 'Feature', geometry: { type: 'Point', coordinates: [p.lng, p.lat] },
      properties: { id: p.id, colour: p.colour, stage: p.stage, hot: p.hot ? 1 : 0, live: p.live ? 1 : 0 }
    })) });
    // a new event since the last refresh: one ripple from its dot (none on the first load)
    const ids = new Set(this.lastPins.map((p) => p.id));
    if (this.seen) {
      const fresh = this.lastPins.filter((p) => p.fresh && !this.seen!.has(p.id));
      if (fresh.length) this.rippleOut(fresh);
    }
    this.seen = ids;
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
        el.innerHTML = `<span class="lm-car__arrow" aria-hidden="true"></span><span class="lm-car__body" aria-hidden="true">${s.photo ? `<img alt="" src="${encodeURI(s.photo)}" decoding="async">` : ''}</span>`;
        const marker = new this.ml.Marker({ element: el, anchor: 'center' }).setLngLat([s.lng, s.lat]).addTo(this.map);
        v = { el, marker, lng: s.lng, lat: s.lat, anim: 0 };
        this.cars.set(s.id, v);
      }
      v.el.style.setProperty('--c', s.colour);
      v.el.style.setProperty('--h', `${s.heading ?? 0}deg`);
      v.el.classList.toggle('lm-car--still', s.heading === null);
      v.el.setAttribute('aria-label', s.label);
      if (v.lng !== s.lng || v.lat !== s.lat) this.glide(v, s.lng, s.lat);
    }
    for (const [id, v] of this.cars) if (!seen.has(id)) { cancelAnimationFrame(v.anim); v.marker.remove(); this.cars.delete(id); }
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
