// The Live map without WebGL (Release 26): the owner's laptop showed "The map needs WebGL" and no map (Chrome turns
// WebGL off with hardware acceleration off, or on its software-rendering blocklist). This draws the same map with
// Canvas 2D from the same self-hosted files (config.ts), projected with Web Mercator exactly as MapLibre does (512 px
// world at zoom 0), so the framing, the pins and the cards match: the land, the GTA's municipalities, the glow, the
// ridges, the lake, the borders, the arterials and highways, the names, the dots (gathered into a count where they
// crowd), the photo cards (moved apart with a leader line, model.separate), home base and its arcs, and the fleet's cars.
// Same events as engine.ts (hover after a pointer rests, click to pin, a count zooms in), no WebGL and no MapLibre.
import { CAR_SILHOUETTE, arc, mx, my, separate, type Box } from './model';
import { BASEMAP, FRAME_MAX_ZOOM, HIGHWAYS, REGIONS, type Bounds } from './config';
import type { CarSpec, EngineEvents, Pad, PinSpec, Spot } from './engine';

type Pt = [number, number];
type Geo = { type: string; coordinates: unknown };
type Feature = { properties: Record<string, unknown>; geometry: Geo };
const WORLD = 512;
const unmx = (x: number) => x * 360 - 180;
const unmy = (y: number) => (Math.atan(Math.sinh(Math.PI * (1 - 2 * y))) * 180) / Math.PI;
const lerpZ = (z: number, a: number, b: number) => a + (b - a) * Math.max(0, Math.min(1, (z - 7) / 4));
const reduced = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
/** Is WebGL there at all? (MapLibre's own check comes later; this one only spares loading it for nothing.) */
export function hasWebGL(): boolean {
  try {
    const c = document.createElement('canvas');
    return !!(c.getContext('webgl2') || c.getContext('webgl'));
  } catch { return false; }
}

export class CanvasMap {
  mode: 'loading' | 'map' | 'nogl' = 'loading';
  private canvas = document.createElement('canvas');
  private layer = document.createElement('div');
  private data: { base: Feature[]; land: Feature[]; hwy: Feature[] } | null = null;
  private cam = { x: 0.5, y: 0.5, z: 8 };
  private pins: PinSpec[] = [];
  private cars: CarSpec[] = [];
  private hq: Pt | null = null;
  private photos = new Map<string, { el: HTMLDivElement; key: string; w: number; h: number }>();
  private carEls = new Map<string, HTMLDivElement>();
  private hqEl: HTMLDivElement | null = null;
  private placed = new Map<string, { x: number; y: number }>();
  private hits: Array<{ id: string | null; x: number; y: number; r: number; n?: number }> = [];
  private hovered: string | null = null;
  private lastFrame: [Bounds, Bounds, Pad] | null = null;
  private fitKey = '';
  private raf = 0;
  private back: ReturnType<typeof setTimeout> | undefined;
  private ro: ResizeObserver | null = null;
  private dead = false;

  constructor(private box: HTMLElement, private ev: EngineEvents, private o: { tv: boolean; scale: number }) {}

  async start(): Promise<'map' | 'nogl'> {
    const ctx = this.canvas.getContext('2d');
    if (!ctx) { this.mode = 'nogl'; return 'nogl'; }
    try {
      const get = async (u: string) => ((await (await fetch(u)).json()) as { features: Feature[] }).features;
      const [base, land, hwy] = await Promise.all([get(BASEMAP), get(REGIONS), get(HIGHWAYS)]);
      if (this.dead) return 'nogl';
      this.data = { base, land, hwy };
    } catch (e) {
      this.box.dataset.error = String(e instanceof Error ? e.message : e).slice(0, 200);
      this.mode = 'nogl';
      return 'nogl';
    }
    this.canvas.className = 'lm-canvas';
    this.layer.className = 'lm-canvas__layer';
    this.box.append(this.canvas, this.layer);
    this.wire();
    if (typeof ResizeObserver !== 'undefined') { this.ro = new ResizeObserver(() => this.draw()); this.ro.observe(this.box); }
    this.mode = 'map';
    this.draw();
    return 'map';
  }

  destroy() {
    this.dead = true;
    cancelAnimationFrame(this.raf); clearTimeout(this.back);
    this.ro?.disconnect();
    this.canvas.remove(); this.layer.remove();
  }

  setPins(p: PinSpec[]) { this.pins = p; this.box.dataset.pins = String(p.length); this.box.dataset.photos = String(p.filter((x) => x.photo).length); this.draw(); }
  setCars(c: CarSpec[]) { this.cars = c; this.draw(); }
  setHq(at: { lat: number; lng: number } | null) { this.hq = at ? [at.lng, at.lat] : null; this.draw(); }

  // ---------------------------------------------------------------- the camera (the same sums as MapLibre's fitBounds)
  private size() { return { w: this.box.clientWidth, h: this.box.clientHeight }; }
  private scale(z = this.cam.z) { return WORLD * 2 ** z; }
  project([lng, lat]: Pt, cam = this.cam): Pt {
    const { w, h } = this.size(), s = WORLD * 2 ** cam.z;
    return [(mx(lng) - cam.x) * s + w / 2, (my(lat) - cam.y) * s + h / 2];
  }
  private unproject(x: number, y: number): Pt {
    const { w, h } = this.size(), s = this.scale();
    return [unmx(this.cam.x + (x - w / 2) / s), unmy(this.cam.y + (y - h / 2) / s)];
  }
  private camFor(b: Bounds, p: Pad) {
    const { w, h } = this.size();
    const x0 = mx(b[0]), x1 = mx(b[2]), y0 = my(b[3]), y1 = my(b[1]);
    const fit = Math.min((w - p.left - p.right) / Math.max(1e-9, x1 - x0), (h - p.top - p.bottom) / Math.max(1e-9, y1 - y0));
    const z = Math.min(Math.log2(Math.max(1, fit) / WORLD), FRAME_MAX_ZOOM), s = WORLD * 2 ** z;
    return { x: (x0 + x1) / 2 - (p.left - p.right) / 2 / s, y: (y0 + y1) / 2 - (p.top - p.bottom) / 2 / s, z };
  }

  /** The same rule as engine.frame: the owner's box edge to edge, or the box and every pin when a pin would sit under the UI. */
  frame(home: Bounds, all: Bounds, pad: Pad) {
    this.lastFrame = [home, all, pad];
    const { w, h } = this.size();
    if (!w || !h) return;
    const k = this.o.scale, half = this.card(false).h / 2 + 6 * k;
    const p1 = { top: pad.top + half, right: pad.right + half, bottom: pad.bottom + half, left: pad.left + half };
    const c0 = this.camFor(home, pad);
    const [x0, y0] = this.project([all[0], all[3]], c0), [x1, y1] = this.project([all[2], all[1]], c0);
    const usePins = x0 < p1.left || y0 < p1.top || x1 > w - p1.right || y1 > h - p1.bottom;
    const key = [...(usePins ? all : home).map((x) => x.toFixed(3)), ...Object.values(usePins ? p1 : pad).map(Math.round), w, h].join(',');
    if (key === this.fitKey) return;
    this.fitKey = key;
    this.cam = usePins ? this.camFor(all, p1) : c0;
    this.box.dataset.frame = usePins ? 'pins' : 'home';
    this.ev.moved();
    this.draw();
  }
  reframe() {
    if (!this.lastFrame) return;
    this.fitKey = '';
    this.frame(...this.lastFrame);
  }
  focus(id: string) {
    const p = this.pins.find((x) => x.id === id);
    if (!p) return;
    this.cam = { x: mx(p.lng), y: my(p.lat), z: Math.max(this.cam.z, 11.5) };
    this.fitKey = '';
    this.ev.moved();
    this.drawNow();
    const at = this.placed.get(id) ?? (() => { const [x, y] = this.project([p.lng, p.lat]); return { x, y }; })();
    this.ev.select(id, this.spot(at.x, at.y, 12, 12));
  }

  private card(small: boolean) {
    const k = this.o.scale * (this.o.tv ? 1 : this.box.clientWidth < 560 ? 0.6 : 0.8), w = (small ? 66 : 80) * k;
    return { w, h: Math.round(w * 0.66) };
  }
  private spot(x: number, y: number, w: number, h: number): Spot {
    return { x: x - w / 2, y: y - h / 2, w, h, bw: this.box.clientWidth, bh: this.box.clientHeight };
  }

  // ---------------------------------------------------------------- pointer: the same as the WebGL map's
  private wire() {
    const hit = (e: MouseEvent) => {
      const r = this.canvas.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
      let best: (typeof this.hits)[number] | null = null, d = Infinity;
      for (const h of this.hits) { const q = Math.hypot(h.x - x, h.y - y); if (q <= h.r && q < d) { d = q; best = h; } }
      return { best, x, y };
    };
    this.canvas.addEventListener('mousemove', (e) => {
      const { best } = hit(e);
      this.canvas.style.cursor = best ? 'pointer' : '';
      const id = best && best.id ? best.id : null;
      if (id === this.hovered) return;
      this.hovered = id;
      this.ev.hover(id, id && best ? this.spot(best.x, best.y, 12, 12) : null);
    });
    this.canvas.addEventListener('mouseleave', () => { if (this.hovered) { this.hovered = null; this.ev.hover(null, null); } });
    this.canvas.addEventListener('click', (e) => {
      const { best, x, y } = hit(e);
      if (!best) return this.ev.select(null, null);
      if (best.id) return this.ev.select(best.id, this.spot(best.x, best.y, 12, 12));
      // a count: zoom in on it (a TV goes back to its frame after 20 seconds)
      const [lng, lat] = this.unproject(x, y);
      this.cam = { x: mx(lng), y: my(lat), z: Math.min(this.cam.z + 1.6, 12) };
      this.fitKey = '';
      this.ev.moved();
      this.draw();
      if (this.o.tv) { clearTimeout(this.back); this.back = setTimeout(() => this.reframe(), 20_000); }
    });
  }

  // ---------------------------------------------------------------- drawing
  private draw() {
    if (this.dead || !this.data) return;
    cancelAnimationFrame(this.raf);
    this.raf = requestAnimationFrame(() => this.drawNow());
  }

  private drawNow() {
    if (this.dead || !this.data) return;
    const { w, h } = this.size();
    if (!w || !h) return;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    if (this.canvas.width !== Math.round(w * dpr) || this.canvas.height !== Math.round(h * dpr)) { this.canvas.width = Math.round(w * dpr); this.canvas.height = Math.round(h * dpr); }
    const c = this.canvas.getContext('2d')!;
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    const k = this.o.scale, z = this.cam.z, P = (pt: Pt) => this.project(pt);
    const { base, land, hwy } = this.data;
    const of = (fs: Feature[], key: string, val: unknown) => fs.filter((f) => f.properties[key] === val);
    const lines = (g: Geo): Pt[][] => (g.type === 'LineString' ? [g.coordinates as Pt[]] : g.type === 'MultiLineString' ? (g.coordinates as Pt[][]) : []);
    const polys = (g: Geo): Pt[][][] => (g.type === 'Polygon' ? [g.coordinates as Pt[][]] : g.type === 'MultiPolygon' ? (g.coordinates as Pt[][][]) : []);
    const fillPolys = (fs: Feature[], colour: string) => {
      c.beginPath();
      for (const f of fs) for (const poly of polys(f.geometry)) for (const ring of poly) ring.forEach((pt, i) => { const [x, y] = P(pt); if (i) c.lineTo(x, y); else c.moveTo(x, y); });
      c.fillStyle = colour; c.fill('evenodd');
    };
    const stroke = (ls: Pt[][], colour: string, width: number, alpha = 1, dash: number[] = []) => {
      c.beginPath();
      for (const l of ls) l.forEach((pt, i) => { const [x, y] = P(pt); if (i) c.lineTo(x, y); else c.moveTo(x, y); });
      c.strokeStyle = colour; c.lineWidth = width; c.globalAlpha = alpha; c.setLineDash(dash); c.lineJoin = 'round'; c.lineCap = 'round';
      c.stroke(); c.globalAlpha = 1; c.setLineDash([]);
    };
    const glow = (pts: Array<[Pt, number]>, r: number, rgb: string, a: number) => {
      c.save(); c.globalCompositeOperation = 'lighter';
      for (const [pt, wgt] of pts) {
        const [x, y] = P(pt);
        if (x < -r || y < -r || x > w + r || y > h + r) continue;
        const g = c.createRadialGradient(x, y, 0, x, y, r);
        g.addColorStop(0, `rgba(${rgb},${(a * wgt).toFixed(3)})`); g.addColorStop(1, `rgba(${rgb},0)`);
        c.fillStyle = g; c.fillRect(x - r, y - r, 2 * r, 2 * r);
      }
      c.restore();
    };

    // the land, the GTA a shade lighter, the glow where people live, the ridges, the lead heat: all under the water
    c.fillStyle = '#11161f'; c.fillRect(0, 0, w, h);
    fillPolys(of(land, 'k', 'muni'), '#161d29');
    const people: Array<[Pt, number]> = [];
    for (const f of of(land, 'k', 'glow')) for (const pt of f.geometry.coordinates as Pt[]) people.push([pt, Number(f.properties.w) || 0]);
    glow(people, 12 * k * 2 ** ((z - 7) * (Math.log2(170 / 12) / 4)), '66,86,124', 0.16);
    for (const f of of(land, 'k', 'ridge')) {
      const ls = lines(f.geometry), wd = lerpZ(z, 30, 64) * k;
      for (const [f2, a] of [[1, 0.1], [0.6, 0.12], [0.3, 0.14]] as const) stroke(ls, '#2f3a50', wd * f2, a);
    }
    glow(this.pins.map((p) => [[p.lng, p.lat] as Pt, p.hot ? 1 : 0.55]), lerpZ(z, 30, 60) * k, '34,211,238', 0.28);
    // the borders (under the lake, which trims them at the shore)
    for (const f of of(land, 'k', 'border')) {
      if (f.properties.lvl === 'muni') stroke(lines(f.geometry), '#45526b', lerpZ(z, 0.8, 1.1) * k, 0.8, [2 * k, 2 * k]);
      else { stroke(lines(f.geometry), '#5b6f96', lerpZ(z, 5, 8) * k, 0.12); stroke(lines(f.geometry), '#55678a', lerpZ(z, 1.1, 1.6) * k, 0.8); }
    }
    // the water, near black, with one fine shore line
    const water = of(base, 'k', 'water');
    fillPolys(water, '#07090e');
    for (const f of water) for (const poly of polys(f.geometry)) { stroke(poly, '#24344d', 4 * k, 0.35); stroke(poly, '#334560', 0.9 * k, 0.85); }
    // roads: Natural Earth's outside the GTA, the arterials, the highways with a faint amber glow
    for (const f of of(base, 'k', 'road')) stroke(lines(f.geometry), '#6e5a3c', lerpZ(z, 0.7, 1.1) * k, 0.5);
    for (const f of of(land, 'k', 'arterial')) stroke(lines(f.geometry), '#5d6a82', lerpZ(z, 0.7, 1.3) * k, lerpZ(z, 0.45, 0.7));
    for (const f of hwy) stroke(lines(f.geometry), '#f59e0b', lerpZ(z, 5, 8) * k, 0.07);
    for (const f of hwy) stroke(lines(f.geometry), f.properties.kind === 'parkway' ? '#7a6646' : '#9a7a4e', lerpZ(z, f.properties.kind === 'parkway' ? 0.7 : 1, f.properties.kind === 'parkway' ? 1.3 : 1.8) * k, 0.7);

    // home base's delivery arcs
    if (this.hq) for (const p of this.pins.filter((x) => x.photo?.route)) stroke([arc(this.hq, [p.lng, p.lat])], '#a7f3d0', 1.4 * k, 0.45, [3 * k, 4 * k]);

    // the photo cards, home base and the cars as page elements; the cards moved apart as on the WebGL map
    // what sits over the map (the TV's numbers and On the road) is out of bounds for the names too
    const taken: Array<[number, number, number, number]> = [];
    const pad = this.lastFrame?.[2];
    if (pad) { taken.push([0, 0, w, Math.max(0, pad.top - 8)]); taken.push([0, h - Math.max(0, pad.bottom - 40 * k), w, h]); }
    this.syncPhotos(taken);
    this.syncHq(taken);
    this.syncCars(taken);
    for (const [id, at] of this.placed) {
      const p = this.pins.find((x) => x.id === id);
      if (!p) continue;
      const [x, y] = P([p.lng, p.lat]);
      if (Math.hypot(at.x - x, at.y - y) > 2) {
        c.beginPath(); c.moveTo(x, y); c.lineTo(at.x, at.y); c.strokeStyle = p.colour; c.globalAlpha = 0.55; c.lineWidth = 1.2 * k; c.stroke(); c.globalAlpha = 1;
        c.beginPath(); c.arc(x, y, 3 * k, 0, Math.PI * 2); c.fillStyle = p.colour; c.fill(); c.lineWidth = 1.2 * k; c.strokeStyle = '#07090e'; c.stroke();
      }
    }

    // the dots, gathered into a count where they crowd (as MapLibre's clusters, 26 px)
    this.hits = [];
    const dots = this.pins.filter((p) => !p.photo).map((p) => ({ p, at: P([p.lng, p.lat]) }));
    const groups: Array<{ x: number; y: number; items: typeof dots }> = [];
    const R = 26 * k;
    for (const d of dots) {
      if (d.at[0] < -40 || d.at[1] < -40 || d.at[0] > w + 40 || d.at[1] > h + 40) continue;
      const g = z < 10 ? groups.find((q) => Math.hypot(q.x - d.at[0], q.y - d.at[1]) < R) : undefined;
      if (g) g.items.push(d); else groups.push({ x: d.at[0], y: d.at[1], items: [d] });
    }
    const names: Array<{ x: number; y: number; who: string; known: boolean }> = [];
    for (const g of groups) {
      if (g.items.length === 1) {
        const { p } = g.items[0]!, r = (p.hot ? 7 : 5.5) * k;
        c.save(); c.shadowColor = p.colour; c.shadowBlur = (p.hot ? 16 : 11) * k;
        c.beginPath(); c.arc(g.x, g.y, r, 0, Math.PI * 2); c.fillStyle = p.colour; c.fill(); c.restore();
        c.lineWidth = 1.5 * k; c.strokeStyle = '#07090e'; c.stroke();
        this.hits.push({ id: p.id, x: g.x, y: g.y, r: r + 6 * k });
        if (z >= 7.5) names.push({ x: g.x + r + 5 * k, y: g.y, who: p.who, known: p.known });
      } else {
        const n = g.items.length, colour = (['booked', 'progress', 'site', 'past'].map((s) => g.items.find((i) => i.p.stage === s)?.p.colour).find(Boolean)) ?? '#94a3b8';
        const r = (n >= 40 ? 19 : n >= 10 ? 16 : 13) * k;
        c.save(); c.shadowColor = colour; c.shadowBlur = 18 * k;
        c.beginPath(); c.arc(g.x, g.y, r, 0, Math.PI * 2); c.fillStyle = '#0f1624'; c.fill(); c.restore();
        c.lineWidth = 2 * k; c.strokeStyle = colour; c.stroke();
        c.fillStyle = '#e8eef8'; c.font = `600 ${13 * k}px Inter, system-ui, sans-serif`; c.textAlign = 'center'; c.textBaseline = 'middle';
        c.fillText(String(n), g.x, g.y + 0.5 * k);
        this.hits.push({ id: null, x: g.x, y: g.y, r, n });
        taken.push([g.x - r, g.y - r, g.x + r, g.y + r]);
      }
    }
    for (const d of this.hits) if (d.id) taken.push([d.x - 7 * k, d.y - 7 * k, d.x + 7 * k, d.y + 7 * k]);

    // the names: cities first, the owner's GTA cities, the towns, then the leads' names; none on top of another or a pin
    const free = (b: [number, number, number, number]) => b[0] >= 0 && b[1] >= 0 && b[2] <= w && b[3] <= h && !taken.some((t) => b[0] < t[2] && t[0] < b[2] && b[1] < t[3] && t[1] < b[3]);
    const label = (text: string, x: number, y: number, size: number, colour: string, spacing: number, weight: number, off: number, anchors: string[], alpha = 1) => {
      c.font = `${weight} ${size}px Inter, system-ui, sans-serif`;
      (c as CanvasRenderingContext2D & { letterSpacing?: string }).letterSpacing = `${spacing * size}px`;
      const tw = c.measureText(text).width, th = size * 1.1;
      for (const a of anchors) {
        const cx = a === 'left' ? x + off + tw / 2 : a === 'right' ? x - off - tw / 2 : x, cy = a === 'top' ? y + off + th / 2 : a === 'bottom' ? y - off - th / 2 : y;
        const b: [number, number, number, number] = [cx - tw / 2 - 2, cy - th / 2 - 2, cx + tw / 2 + 2, cy + th / 2 + 2];
        if (!free(b)) continue;
        taken.push(b);
        c.textAlign = 'center'; c.textBaseline = 'middle'; c.globalAlpha = alpha;
        c.lineWidth = 3 * k; c.strokeStyle = 'rgba(11,14,20,.9)'; c.strokeText(text, cx, cy);
        c.fillStyle = colour; c.fillText(text, cx, cy); c.globalAlpha = 1;
        (c as CanvasRenderingContext2D & { letterSpacing?: string }).letterSpacing = '0px';
        return true;
      }
      (c as CanvasRenderingContext2D & { letterSpacing?: string }).letterSpacing = '0px';
      return false;
    };
    const around = ['top', 'bottom', 'left', 'right'];
    const cities = of(base, 'k', 'city').sort((a, b) => Number(a.properties.rank) - Number(b.properties.rank));
    for (const f of cities) {
      const [x, y] = P(f.geometry.coordinates as Pt), rank = Number(f.properties.rank);
      label(String(f.properties.name).toUpperCase(), x, y, (rank === 1 ? 17 : rank === 2 ? 13.5 : 12.5) * k, rank === 1 ? '#c3cee0' : '#93a1b8', 0.2, 600, (this.o.tv ? 2.9 : 2.4) * 13 * k * 0.5, around);
    }
    if (z >= 7) for (const f of of(land, 'k', 'town').sort((a, b) => Number(a.properties.rank) - Number(b.properties.rank))) {
      const [x, y] = P(f.geometry.coordinates as Pt), big = f.properties.rank === 3;
      label(String(f.properties.name).toUpperCase(), x, y, (big ? 12 : 10.5) * k, big ? '#8f9cb3' : '#647189', 0.16, big ? 600 : 400, (this.o.tv ? 2.6 : 2.2) * 11 * k * 0.5, [...around, 'center']);
    }
    for (const f of of(land, 'k', 'region')) { const [x, y] = P(f.geometry.coordinates as Pt); label(String(f.properties.name).toUpperCase(), x, y, 13 * k, '#4d5b78', 0.5, 600, 0, ['center'], 0.75); }
    for (const n of names.sort((a, b) => Number(b.known) - Number(a.known))) label(n.who, n.x, n.y, 11 * k, '#dbe4f3', 0, 600, 0, ['left'], n.known ? 0.95 : 0.6);

    this.box.dataset.zoom = z.toFixed(2);
  }

  /** The photo cards: placed, then moved apart (model.separate), with home base fixed. */
  private syncPhotos(taken: Array<[number, number, number, number]>) {
    const seen = new Set<string>(), boxes: Box[] = [];
    for (const p of this.pins.filter((x) => x.photo)) {
      seen.add(p.id);
      const sz = this.card(p.hot && !p.photo!.route), key = `${p.colour}|${p.photo!.src ?? p.photo!.initial}|${p.hot}|${p.who}|${sz.w}`;
      let v = this.photos.get(p.id);
      if (!v) {
        const el = document.createElement('div');
        el.className = 'lm-ph lm-ph--abs';
        el.tabIndex = this.o.tv ? -1 : 0;
        el.setAttribute('role', 'button');
        const id = p.id, spot = (): Spot => { const r = el.getBoundingClientRect(), b = this.box.getBoundingClientRect(); return { x: r.left - b.left, y: r.top - b.top, w: r.width, h: r.height, bw: b.width, bh: b.height }; };
        el.addEventListener('mouseenter', () => this.ev.hover(id, spot()));
        el.addEventListener('mouseleave', () => this.ev.hover(null, null));
        el.addEventListener('focus', () => this.ev.hover(id, spot()));
        el.addEventListener('blur', () => this.ev.hover(null, null));
        el.addEventListener('click', (e) => { e.stopPropagation(); this.ev.select(id, spot()); });
        this.layer.appendChild(el);
        v = { el, key: '', w: 0, h: 0 };
        this.photos.set(p.id, v);
      }
      v.el.setAttribute('aria-label', p.label);
      if (v.key !== key) {
        v.key = key; v.w = sz.w; v.h = sz.h;
        v.el.style.setProperty('--c', p.colour);
        v.el.style.setProperty('--w', `${sz.w}px`); v.el.style.setProperty('--h', `${sz.h}px`);
        v.el.classList.toggle('lm-ph--hot', p.hot && !p.photo!.route);
        const ini = p.photo!.initial.replace(/[^A-Z0-9]/g, '');
        v.el.innerHTML = (p.photo!.src ? `<img alt="" src="${encodeURI(p.photo!.src)}" decoding="async">` : ini ? `<span aria-hidden="true">${ini}</span>` : `<span class="lm-ph__shape">${CAR_SILHOUETTE}</span>`)
          + '<b class="lm-ph__name" aria-hidden="true"></b>';
        v.el.querySelector('.lm-ph__name')!.textContent = p.who;
      }
      const [x, y] = this.project([p.lng, p.lat]);
      boxes.push({ id: p.id, x, y, w: sz.w, h: sz.h });
    }
    for (const [id, v] of this.photos) if (!seen.has(id)) { v.el.remove(); this.photos.delete(id); }
    const hqPx = 30 * this.o.scale;
    if (this.hq) { const [x, y] = this.project(this.hq); boxes.push({ id: 'home-base', x, y, w: hqPx, h: hqPx, fixed: true }); }
    const at = separate(boxes, 8 * this.o.scale);
    this.placed = new Map();
    let moved = 0;
    for (const b of boxes) {
      const v = this.photos.get(b.id), to = at.get(b.id)!;
      if (!v) continue;
      this.placed.set(b.id, to);
      if (Math.hypot(to.x - b.x, to.y - b.y) > 2) moved++;
      v.el.style.transform = `translate(${to.x - b.w / 2}px, ${to.y - b.h / 2}px)`;
      taken.push([to.x - b.w / 2, to.y - b.h / 2, to.x + b.w / 2, to.y + b.h / 2]);
    }
    this.box.dataset.fanned = String(moved);
  }

  private syncHq(taken: Array<[number, number, number, number]>) {
    if (!this.hq) { this.hqEl?.remove(); this.hqEl = null; return; }
    if (!this.hqEl) {
      this.hqEl = document.createElement('div');
      this.hqEl.className = 'lm-hq lm-hq--abs';
      this.hqEl.setAttribute('role', 'img');
      this.hqEl.setAttribute('aria-label', 'CarmaCars home base');
      this.hqEl.innerHTML = `<span class="lm-hq__pulse" aria-hidden="true"${reduced() ? ' style="animation:none"' : ''}></span><span class="lm-hq__mark" aria-hidden="true">C</span>`;
      this.layer.appendChild(this.hqEl);
    }
    const s = 30 * this.o.scale, [x, y] = this.project(this.hq);
    this.hqEl.style.setProperty('--s', `${s}px`);
    this.hqEl.style.transform = `translate(${x - s / 2}px, ${y - s / 2}px)`;
    taken.push([x - s / 2, y - s / 2, x + s / 2, y + s / 2]);
  }

  private syncCars(taken: Array<[number, number, number, number]>) {
    const seen = new Set<string>(), s = 34 * this.o.scale;
    for (const car of this.cars) {
      seen.add(car.id);
      let el = this.carEls.get(car.id);
      if (!el) {
        el = document.createElement('div');
        el.className = 'lm-car lm-car--abs';
        el.setAttribute('role', 'img');
        el.innerHTML = `<span class="lm-car__arrow" aria-hidden="true"></span><span class="lm-car__body" aria-hidden="true">${car.photo ? `<img alt="" src="${encodeURI(car.photo)}" decoding="async">` : ''}</span>`;
        this.layer.appendChild(el);
        this.carEls.set(car.id, el);
      }
      el.style.setProperty('--s', `${s}px`);
      el.style.setProperty('--c', car.colour);
      el.style.setProperty('--h', `${car.heading ?? 0}deg`);
      el.classList.toggle('lm-car--still', car.heading === null);
      el.setAttribute('aria-label', car.label);
      const [x, y] = this.project([car.lng, car.lat]);
      el.style.transform = `translate(${x - s / 2}px, ${y - s / 2}px)`;
      taken.push([x - s / 2, y - s / 2, x + s / 2, y + s / 2]);
    }
    for (const [id, el] of this.carEls) if (!seen.has(id)) { el.remove(); this.carEls.delete(id); }
  }
}
