// The Live map's drawing (migration 0242), outside React: MapLibre GL JS with OpenFreeMap's dark vector map when the
// browser can load them, else a simplified map drawn here (the lakes and the cities, no tiles), so the pins always show.
// The pins and the fleet's cars are DOM elements kept by id: a refresh moves and restyles them in place (no flicker),
// adds the new ones and removes the gone. The library is loaded once, from its pinned version, on this page only.
import { HOME_BOUNDS, MAPLIBRE_CSS, MAPLIBRE_JS, MAP_ATTRIBUTION, MAP_STYLE, MAX_BOUNDS, type Bounds } from './config';

export interface PinSpec { id: string; lng: number; lat: number; colour: string; type: string; icon: string; label: string; pulse: boolean; selected: boolean; hot: boolean }
export interface CarSpec { id: string; lng: number; lat: number; colour: string; heading: number | null; label: string; photo: string | null }
export interface Spot { x: number; y: number; w: number; h: number; bw: number; bh: number }
export interface EngineEvents { select(id: string | null, at: Spot | null): void; hover(id: string | null, at: Spot | null): void; moved(): void }

type Ml = {
  Map: new (o: Record<string, unknown>) => MlMap;
  Marker: new (o: Record<string, unknown>) => MlMarker;
  AttributionControl: new (o: Record<string, unknown>) => unknown;
  NavigationControl: new (o: Record<string, unknown>) => unknown;
  supported?: () => boolean;
};
type MlMap = {
  on(ev: string, f: (e?: unknown) => void): void; once(ev: string, f: () => void): void; remove(): void; resize(): void; addControl(c: unknown, pos?: string): void;
  fitBounds(b: [[number, number], [number, number]], o?: Record<string, unknown>): void; project(ll: [number, number]): { x: number; y: number };
};
type MlMarker = { setLngLat(ll: [number, number]): MlMarker; addTo(m: MlMap): MlMarker; remove(): void; getLngLat(): { lng: number; lat: number } };

let loading: Promise<Ml | null> | null = null;
/** MapLibre from its CDN (one pinned version), once per page; null when it cannot load in 12 seconds or WebGL is missing. */
export function loadMapLibre(): Promise<Ml | null> {
  const w = window as unknown as { maplibregl?: Ml };
  if (w.maplibregl) return Promise.resolve(w.maplibregl);
  loading ??= new Promise<Ml | null>((resolve) => {
    if (!document.querySelector(`link[href="${MAPLIBRE_CSS}"]`)) {
      const css = document.createElement('link');
      css.rel = 'stylesheet'; css.href = MAPLIBRE_CSS; css.crossOrigin = 'anonymous';
      document.head.appendChild(css);
    }
    const s = document.createElement('script');
    s.src = MAPLIBRE_JS; s.async = true; s.crossOrigin = 'anonymous';
    const give = setTimeout(() => resolve(null), 12_000);
    s.onload = () => { clearTimeout(give); const m = w.maplibregl; resolve(m && (!m.supported || m.supported()) ? m : null); };
    s.onerror = () => { clearTimeout(give); resolve(null); };
    document.head.appendChild(s);
  }).then((m) => { if (!m) loading = null; return m; });
  return loading;
}

// ------------------------------------------------------------------ the simplified map (no tiles)
const LAKE_ONTARIO: Array<[number, number]> = [[-79.88, 43.28], [-79.8, 43.31], [-79.76, 43.33], [-79.69, 43.4], [-79.62, 43.47], [-79.58, 43.54], [-79.52, 43.59],
  [-79.47, 43.62], [-79.4, 43.63], [-79.34, 43.63], [-79.29, 43.66], [-79.2, 43.71], [-79.12, 43.77], [-79.07, 43.81], [-79.0, 43.83], [-78.92, 43.85], [-78.83, 43.86],
  [-78.7, 43.88], [-78.55, 43.91], [-78.4, 43.94], [-78.28, 43.95], [-78.16, 43.95], [-78.0, 43.93], [-77.4, 43.9], [-77.4, 43.2], [-77.6, 43.26], [-78.19, 43.37],
  [-78.71, 43.34], [-78.83, 43.31], [-79.05, 43.26], [-79.2, 43.2], [-79.27, 43.2], [-79.4, 43.19], [-79.56, 43.2], [-79.7, 43.23], [-79.78, 43.25]];
const LAKE_SIMCOE: Array<[number, number]> = [[-79.69, 44.4], [-79.6, 44.36], [-79.5, 44.3], [-79.45, 44.2], [-79.4, 44.19], [-79.3, 44.22], [-79.25, 44.29],
  [-79.18, 44.4], [-79.2, 44.47], [-79.32, 44.55], [-79.42, 44.48], [-79.47, 44.44], [-79.55, 44.42]];
const LAKE_ERIE: Array<[number, number]> = [[-81.5, 42.6], [-80.4, 42.58], [-79.9, 42.83], [-79.25, 42.88], [-78.9, 42.88], [-78.9, 42.2], [-81.5, 42.2]];
const CITIES: Array<[string, number, number, boolean?]> = [['Toronto', -79.38, 43.65, true], ['Mississauga', -79.64, 43.59], ['Brampton', -79.76, 43.73], ['Vaughan', -79.51, 43.84],
  ['Markham', -79.34, 43.86], ['Oakville', -79.69, 43.45], ['Burlington', -79.8, 43.33], ['Hamilton', -79.87, 43.26, true], ['Milton', -79.88, 43.52], ['Pickering', -79.09, 43.84],
  ['Oshawa', -78.86, 43.9], ['Whitby', -78.94, 43.88], ['Newmarket', -79.46, 44.06], ['Barrie', -79.69, 44.39, true], ['Guelph', -80.25, 43.55], ['Kitchener', -80.49, 43.45, true],
  ['Cambridge', -80.31, 43.36], ['St. Catharines', -79.25, 43.16], ['Niagara Falls', -79.08, 43.09], ['Peterborough', -78.32, 44.3, true], ['Cobourg', -78.17, 43.96]];

const merc = (lat: number) => Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360));

class Schematic {
  private svg: SVGSVGElement;
  private bounds: Bounds = HOME_BOUNDS;
  constructor(private box: HTMLElement) {
    this.svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this.svg.setAttribute('class', 'lm-schematic');
    this.svg.setAttribute('aria-hidden', 'true');
    box.appendChild(this.svg);
    this.draw();
  }
  setBounds(b: Bounds) { this.bounds = b; this.draw(); }
  /** Pixel position of a point, the bounds fitted into the box (its aspect kept). */
  project(lng: number, lat: number): { x: number; y: number } {
    const W = this.box.clientWidth || 1, H = this.box.clientHeight || 1, [w, s, e, n] = this.bounds;
    const rad = Math.PI / 180, dx = (e - w) * rad, dy = merc(n) - merc(s);
    const k = Math.min(W / dx, H / dy) * 0.94;
    const ox = (W - dx * k) / 2, oy = (H - dy * k) / 2;
    return { x: ox + (lng - w) * rad * k, y: oy + (merc(n) - merc(lat)) * k };
  }
  draw() {
    const W = this.box.clientWidth || 1, H = this.box.clientHeight || 1;
    this.svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    const poly = (pts: Array<[number, number]>) => pts.map(([x, y]) => { const p = this.project(x, y); return `${p.x.toFixed(1)},${p.y.toFixed(1)}`; }).join(' ');
    const grid: string[] = [];
    for (let lng = -83; lng <= -74; lng += 0.5) { const a = this.project(lng, 41), b = this.project(lng, 47); grid.push(`<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}"/>`); }
    for (let lat = 41; lat <= 47; lat += 0.25) { const a = this.project(-84, lat), b = this.project(-73, lat); grid.push(`<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}"/>`); }
    const fs = Math.max(10, Math.min(W, H) / 60);
    const labels = CITIES.map(([name, x, y, big]) => { const p = this.project(x, y); return `<circle cx="${p.x}" cy="${p.y}" r="${big ? 3 : 2}"/><text x="${p.x + 6}" y="${p.y - 6}" font-size="${big ? fs * 1.15 : fs}"${big ? ' class="big"' : ''}>${name}</text>`; }).join('');
    this.svg.innerHTML = `<g class="g">${grid.join('')}</g><polygon class="w" points="${poly(LAKE_ONTARIO)}"/><polygon class="w" points="${poly(LAKE_SIMCOE)}"/><polygon class="w" points="${poly(LAKE_ERIE)}"/><g class="c">${labels}</g>`;
  }
}

// ------------------------------------------------------------------ the engine
export class MapEngine {
  mode: 'loading' | 'map' | 'schematic' = 'loading';
  private ml: Ml | null = null;
  private map: MlMap | null = null;
  private sch: Schematic | null = null;
  private layer: HTMLDivElement;
  private pins = new Map<string, { el: HTMLButtonElement; marker: MlMarker | null; lng: number; lat: number }>();
  private cars = new Map<string, { el: HTMLDivElement; marker: MlMarker | null; lng: number; lat: number; anim: number }>();
  private lastPins: PinSpec[] = [];
  private lastCars: CarSpec[] = [];
  private fitKey = '';
  private ro: ResizeObserver | null = null;
  private dead = false;

  constructor(private box: HTMLElement, private ev: EngineEvents, private o: { tv: boolean }) {
    this.layer = document.createElement('div');
    this.layer.className = 'lm-overlay';
  }

  async start(): Promise<'map' | 'schematic'> {
    const ml = await loadMapLibre();
    if (this.dead) return 'schematic';
    if (ml) {
      try {
        const map = new ml.Map({
          container: this.box, style: MAP_STYLE, bounds: [[HOME_BOUNDS[0], HOME_BOUNDS[1]], [HOME_BOUNDS[2], HOME_BOUNDS[3]]], maxBounds: [[MAX_BOUNDS[0], MAX_BOUNDS[1]], [MAX_BOUNDS[2], MAX_BOUNDS[3]]],
          fitBoundsOptions: { padding: 24 }, attributionControl: false, dragRotate: false, pitchWithRotate: false, cooperativeGestures: false, minZoom: 5.5, maxZoom: 15,
          interactive: !this.o.tv, fadeDuration: 0
        });
        map.addControl(new ml.AttributionControl({ compact: false, customAttribution: MAP_ATTRIBUTION }), 'bottom-right');
        if (!this.o.tv) map.addControl(new ml.NavigationControl({ showCompass: false }), 'top-right');
        const ok = await new Promise<boolean>((resolve) => {
          const t = setTimeout(() => resolve(false), 15_000);
          map.once('load', () => { clearTimeout(t); resolve(true); });
          map.on('error', () => { /* a tile that failed; the style failing is the timeout */ });
        });
        if (this.dead) { map.remove(); return 'schematic'; }
        if (ok) {
          this.ml = ml; this.map = map; this.mode = 'map';
          map.on('click', () => this.ev.select(null, null));
          map.on('movestart', () => this.ev.moved());
          this.render();
          return 'map';
        }
        map.remove();
      } catch { /* WebGL refused: the simplified map */ }
    }
    this.box.replaceChildren();
    this.sch = new Schematic(this.box);
    this.box.appendChild(this.layer);
    this.layer.addEventListener('click', (e) => { if (e.target === this.layer) this.ev.select(null, null); });
    this.mode = 'schematic';
    this.ro = new ResizeObserver(() => { this.sch?.draw(); this.placeAll(); });
    this.ro.observe(this.box);
    this.render();
    return 'schematic';
  }

  destroy() {
    this.dead = true;
    this.ro?.disconnect();
    for (const c of this.cars.values()) cancelAnimationFrame(c.anim);
    this.map?.remove();
    this.box.replaceChildren();
  }

  setPins(p: PinSpec[]) { this.lastPins = p; if (this.mode !== 'loading') this.syncPins(); }
  setCars(c: CarSpec[]) { this.lastCars = c; if (this.mode !== 'loading') this.syncCars(); }
  /** Frames the area, widened to take in the pins drawn (never past southern Ontario); only when that changes. */
  frame(b: Bounds) {
    const key = b.map((x) => x.toFixed(2)).join(',');
    if (key === this.fitKey) return;
    this.fitKey = key;
    if (this.map) this.map.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: this.o.tv ? 48 : 24, duration: 1200, maxZoom: 11 });
    else if (this.sch) { this.sch.setBounds(b); this.placeAll(); }
  }
  /** Where a pin is in the map's box, for its card. */
  spotOf(id: string): Spot | null {
    const el = this.pins.get(id)?.el;
    if (!el) return null;
    const r = el.getBoundingClientRect(), b = this.box.getBoundingClientRect();
    return { x: r.left - b.left, y: r.top - b.top, w: r.width, h: r.height, bw: b.width, bh: b.height };
  }

  private render() { this.syncPins(); this.syncCars(); }

  private place(el: HTMLElement, lng: number, lat: number) {
    if (!this.sch) return;
    const p = this.sch.project(lng, lat);
    el.style.transform = `translate(${p.x.toFixed(1)}px, ${p.y.toFixed(1)}px)`;
  }
  private placeAll() {
    for (const v of this.pins.values()) this.place(v.el, v.lng, v.lat);
    for (const v of this.cars.values()) this.place(v.el, v.lng, v.lat);
  }

  private syncPins() {
    const seen = new Set<string>();
    // hot pins last, so they are drawn on top
    for (const s of [...this.lastPins].sort((a, b) => Number(a.hot) - Number(b.hot))) {
      seen.add(s.id);
      let v = this.pins.get(s.id);
      if (!v) {
        const el = document.createElement('button');
        el.type = 'button';
        el.dataset.id = s.id;
        const id = s.id;
        el.addEventListener('click', (e) => { e.stopPropagation(); this.ev.select(id, this.spotOf(id)); });
        el.addEventListener('mouseenter', () => this.ev.hover(id, this.spotOf(id)));
        el.addEventListener('mouseleave', () => this.ev.hover(null, null));
        el.addEventListener('focus', () => this.ev.hover(id, this.spotOf(id)));
        el.addEventListener('blur', () => this.ev.hover(null, null));
        const marker = this.map && this.ml ? new this.ml.Marker({ element: el, anchor: 'center' }).setLngLat([s.lng, s.lat]).addTo(this.map) : null;
        if (!marker) this.layer.appendChild(el);
        v = { el, marker, lng: s.lng, lat: s.lat };
        this.pins.set(s.id, v);
      }
      const el = v.el;
      // our classes only: MapLibre keeps its own on the marker (maplibregl-marker)
      const want = ['lm-pin', `lm-pin--${s.type}`, ...(s.pulse ? ['lm-pin--pulse'] : []), ...(s.selected ? ['lm-pin--on'] : []), ...(s.hot ? ['lm-pin--hot'] : [])];
      for (const c of [...el.classList]) if (c.startsWith('lm-pin') && !want.includes(c)) el.classList.remove(c);
      el.classList.add(...want);
      if (el.style.getPropertyValue('--c') !== s.colour) el.style.setProperty('--c', s.colour);
      if (el.getAttribute('aria-label') !== s.label) el.setAttribute('aria-label', s.label);
      el.setAttribute('aria-pressed', String(s.selected));
      if (el.dataset.icon !== s.type) { el.dataset.icon = s.type; el.innerHTML = `<span class="lm-pin__dot">${s.icon}</span>`; }
      if (v.lng !== s.lng || v.lat !== s.lat || !v.marker) {
        v.lng = s.lng; v.lat = s.lat;
        if (v.marker) v.marker.setLngLat([s.lng, s.lat]); else this.place(el, s.lng, s.lat);
      }
      el.style.zIndex = s.selected ? '30' : s.hot ? '20' : s.pulse ? '15' : '10';
    }
    for (const [id, v] of this.pins) if (!seen.has(id)) { if (v.marker) v.marker.remove(); else v.el.remove(); this.pins.delete(id); }
  }

  private syncCars() {
    const seen = new Set<string>();
    for (const s of this.lastCars) {
      seen.add(s.id);
      let v = this.cars.get(s.id);
      if (!v) {
        const el = document.createElement('div');
        el.className = 'lm-car';
        el.setAttribute('role', 'img');
        el.innerHTML = `<span class="lm-car__arrow" aria-hidden="true"></span><span class="lm-car__body" aria-hidden="true">${s.photo ? `<img alt="" src="${encodeURI(s.photo)}" loading="lazy" decoding="async">` : '<svg viewBox="0 0 24 24"><path d="M5 11l1.5-4.5A2 2 0 0 1 8.4 5h7.2a2 2 0 0 1 1.9 1.5L19 11v6a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1v-1H8v1a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1z" fill="currentColor"/></svg>'}</span>`;
        const marker = this.map && this.ml ? new this.ml.Marker({ element: el, anchor: 'center' }).setLngLat([s.lng, s.lat]).addTo(this.map) : null;
        if (!marker) { this.layer.appendChild(el); }
        v = { el, marker, lng: s.lng, lat: s.lat, anim: 0 };
        this.cars.set(s.id, v);
        if (!marker) this.place(el, s.lng, s.lat);
      }
      v.el.style.setProperty('--c', s.colour);
      v.el.style.setProperty('--h', `${s.heading ?? 0}deg`);
      v.el.classList.toggle('lm-car--still', s.heading === null);
      v.el.setAttribute('aria-label', s.label);
      if (v.lng !== s.lng || v.lat !== s.lat) this.glide(v, s.lng, s.lat);
    }
    for (const [id, v] of this.cars) if (!seen.has(id)) { cancelAnimationFrame(v.anim); if (v.marker) v.marker.remove(); else v.el.remove(); this.cars.delete(id); }
  }

  /** A car moves smoothly to its new position over two seconds (at once with reduced motion). */
  private glide(v: { el: HTMLDivElement; marker: MlMarker | null; lng: number; lat: number; anim: number }, lng: number, lat: number) {
    cancelAnimationFrame(v.anim);
    const from = { lng: v.lng, lat: v.lat }, t0 = performance.now(), ms = matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 2000;
    const step = (t: number) => {
      const k = ms ? Math.min(1, (t - t0) / ms) : 1, e = k < 0.5 ? 2 * k * k : 1 - (-2 * k + 2) ** 2 / 2;
      v.lng = from.lng + (lng - from.lng) * e; v.lat = from.lat + (lat - from.lat) * e;
      if (v.marker) v.marker.setLngLat([v.lng, v.lat]); else this.place(v.el, v.lng, v.lat);
      if (k < 1) v.anim = requestAnimationFrame(step);
    };
    v.anim = requestAnimationFrame(step);
  }
}
