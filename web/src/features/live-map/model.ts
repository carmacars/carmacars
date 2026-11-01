// The Live map (migration 0242): what the database's one read (admin_read live_map) returns, and what the website works
// out from it: the score and its signals, the masked contact details, where each pin goes (spread a little when several
// share a spot, the same way on every refresh), the counts and the spotlight. No imports: unit tested in Node.

export type LeadType = 'session' | 'game' | 'draft' | 'lead' | 'request' | 'booking' | 'on_rent' | 'previous';
export type Precision = 'visit' | 'home_city' | 'visit_city' | null;

export interface CarPhoto { path: string; variants?: Array<{ width: number; path: string; format?: string }> | null; alt?: string; sample?: boolean }
export interface MapCar { id: string; code: string | null; name: string; daily_cents: number | null; photo: CarPhoto | null; how: string }
export interface LiveReason { kind?: string; label: string; why?: string; weight: number }
export interface Facts { pages: number; seconds: number; cars: number; visit: number; past: number; game: boolean; claimed: boolean; live_score: number | null; reasons: LiveReason[] }
export interface RawPin {
  id: string; type: LeadType; types: LeadType[]; at: string; detail: string | null; booking_number: string | null; renter_id: string | null; session_id: string | null;
  pickup_at?: string | null; return_at?: string | null;
  name: string | null; email: string | null; phone: string | null; city: string | null; lat: number | null; lng: number | null; precision: Precision;
  online: boolean | null; device: string | null; from_ad: boolean; facts: Facts; car: MapCar | null;
}
export interface FleetCar { vehicle_id: string; code: string | null; name: string; lat: number; lng: number; heading: number | null; speed: number | null; status: 'on_rent' | 'available' | 'in_service'; updated_at: string; photo: CarPhoto | null }
export interface Kpi { active_now: number; requests_today: number; requests_yesterday?: number; bookings_week: number; on_rent_now: number; collected_month_cents: number | null }
export interface RawMap { at: string; days: number; cap: number; live_minutes: number; hq?: { lat: number; lng: number } | null; kpi: Kpi; totals: Partial<Record<LeadType, number>>; pins: RawPin[]; fleet: FleetCar[] }

export interface Signal { label: string; points: number; live?: boolean }
export interface Pin {
  id: string; type: LeadType; types: LeadType[]; at: string; detail: string | null; booking_number: string | null; renter_id: string | null; session_id: string | null;
  pickup_at: string | null; return_at: string | null;
  who: string; anonymous: boolean; email: string | null; phone: string | null; city: string | null; lat: number | null; lng: number | null; precision: Precision;
  online: boolean; device: string | null; score: number; band: 'hot' | 'warm' | 'cold'; signals: Signal[]; car: MapCar | null; masked: boolean;
}
export interface MapView { at: string; days: number; cap: number; hq: { lat: number; lng: number } | null; kpi: Kpi; totals: Partial<Record<LeadType, number>>; pins: Pin[]; fleet: FleetCar[]; masked: boolean }

/** Most advanced first; the legend's order. Colours are for a dark map (each has 4.5:1 or more against #0b1020). */
export const TYPES: Array<{ type: LeadType; label: string; short: string; colour: string }> = [
  { type: 'on_rent', label: 'On rent now', short: 'On rent', colour: '#4ade80' },
  { type: 'booking', label: 'Booking (upcoming)', short: 'Booking', colour: '#2dd4bf' },
  { type: 'request', label: 'Request', short: 'Request', colour: '#a5b4fc' },
  { type: 'lead', label: 'Form sent', short: 'Form sent', colour: '#fb923c' },
  { type: 'draft', label: 'Unfinished form', short: 'Unfinished', colour: '#facc15' },
  { type: 'game', label: 'Game player', short: 'Game', colour: '#f0abfc' },
  { type: 'previous', label: 'Previous renter', short: 'Past renter', colour: '#cbd5e1' },
  { type: 'session', label: 'On the site now', short: 'On site', colour: '#38bdf8' }
];
export const TYPE: Record<LeadType, { label: string; short: string; colour: string }> = Object.fromEntries(TYPES.map((t) => [t.type, t])) as unknown as Record<LeadType, { label: string; short: string; colour: string }>;
/** Four stages for the wall: one hue each (green booked, amber in progress, cyan on the site, grey past). */
export type Stage = 'booked' | 'progress' | 'site' | 'past';
export const STAGES: Array<{ stage: Stage; label: string; colour: string; types: LeadType[] }> = [
  { stage: 'booked', label: 'On rent or booked', colour: '#34d399', types: ['on_rent', 'booking'] },
  { stage: 'progress', label: 'Requests and forms', colour: '#fbbf24', types: ['request', 'lead', 'draft'] },
  { stage: 'site', label: 'On site and games', colour: '#22d3ee', types: ['session', 'game'] },
  { stage: 'past', label: 'Past renters', colour: '#94a3b8', types: ['previous'] }
];
export const stageOf = (t: LeadType): Stage => STAGES.find((s) => s.types.includes(t))?.stage ?? 'site';
export const STAGE: Record<Stage, { label: string; colour: string; types: LeadType[] }> = Object.fromEntries(STAGES.map((s) => [s.stage, s])) as unknown as Record<Stage, { label: string; colour: string; types: LeadType[] }>;

/** What happened, for the feed: "started a booking", "sent a request". */
export function verbOf(p: { type: LeadType; detail: string | null; signals?: Signal[] }): string {
  switch (p.type) {
    case 'on_rent': return 'is on rent';
    case 'booking': return 'booked';
    case 'request': return 'sent a request';
    case 'lead': return 'sent a form';
    case 'draft': return /booking/i.test(p.detail ?? '') ? 'started a booking' : 'started a form';
    case 'game': return p.signals?.some((s) => s.label === 'Claimed a game prize') ? 'won a discount' : 'played a game';
    case 'previous': return 'came back';
    default: return 'is on the site';
  }
}
/** The one reason line: the two strongest signals after the stage itself ("Pickup tomorrow · Saw the full price"). */
export function reasonOf(signals: Signal[]): string {
  const steps = new Set(Object.values(TYPE_POINTS).map((x) => x![0]));
  return signals.filter((s) => !steps.has(s.label)).slice(0, 2).map((s) => s.label).join(' · ');
}
/** Who gets a photo pin: on rent, booked, or hot (score 60 or more), with a car to show; at most `max`, the most advanced and hottest first. */
export function photoPins(pins: Pin[], max = 60): Set<string> {
  const want = pins.filter((p) => !!p.car && (p.type === 'on_rent' || p.type === 'booking' || p.band === 'hot'));
  const rank = (p: Pin) => (p.type === 'on_rent' ? 0 : p.type === 'booking' ? 1 : 2);
  return new Set(want.sort((a, b) => rank(a) - rank(b) || b.score - a.score).slice(0, max).map((p) => p.id));
}
/** The make's initial for a car with no photo: "2024 Toyota Corolla" is T. */
export function makeInitial(name: string | null | undefined): string {
  const w = (name ?? '').trim().split(/\s+/).filter((x) => x && !/^\d{4}$/.test(x));
  return (w[0]?.charAt(0) ?? '?').toUpperCase();
}
/** A neutral car seen from the side (currentColor), for a card or pin with no photo and no make to show. */
export const CAR_SILHOUETTE = '<svg viewBox="0 0 48 24" width="100%" height="100%" fill="currentColor" aria-hidden="true" focusable="false">'
  + '<path d="M4 15.6c0-1.6 1.1-3 2.7-3.3l5.6-1.2 4.9-4.6a6 6 0 0 1 4.1-1.7h7.4c1.8 0 3.5.8 4.6 2.2l3.6 4.5 4.6.9a3.2 3.2 0 0 1 2.5 3.2V17a1.5 1.5 0 0 1-1.5 1.5h-2.1a4.6 4.6 0 0 0-9 0H16.6a4.6 4.6 0 0 0-9 0H5.5A1.5 1.5 0 0 1 4 17z" opacity=".55"/>'
  + '<path d="M17.4 11.2l3.4-3.1a3.6 3.6 0 0 1 2.4-.9h3.1v4zm10.9 0v-4h.6c1.1 0 2.1.5 2.8 1.4l2.1 2.6z" opacity=".35"/>'
  + '<circle cx="12.1" cy="18.6" r="3.3"/><circle cx="35.9" cy="18.6" r="3.3"/></svg>';
/** What a card says about the car: its name, or "Car not assigned" for a booking with no car yet; the make's initial
 * when there is a name to take it from, else null (draw CAR_SILHOUETTE). Never "Car ?". */
export function carLabel(car: Pick<MapCar, 'name' | 'code'> | null | undefined): { name: string; assigned: boolean; initial: string | null } {
  if (!car) return { name: 'Car not assigned', assigned: false, initial: null };
  const name = (car.name ?? '').trim() || (car.code ? `Car ${car.code}` : 'Car');
  const initial = makeInitial(car.name);
  return { name, assigned: true, initial: initial === '?' ? null : initial };
}
/** The cars on the road today: on rent now, or booked with pickup today (Toronto), earliest due first. */
export function onTheRoad(pins: Pin[], now = Date.now()): Pin[] {
  const day = (iso: string | number) => new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });
  const today = day(now);
  return pins.filter((p) => p.type === 'on_rent' || (p.type === 'booking' && !!p.pickup_at && day(p.pickup_at) === today))
    .sort((a, b) => (a.type === b.type ? 0 : a.type === 'on_rent' ? -1 : 1) || String(a.return_at ?? a.pickup_at).localeCompare(String(b.return_at ?? b.pickup_at)));
}
/** A gently curved arc from a to b (bowed to the left of the way, a fifth of its length), as points: at this scale a
 * great circle is a straight line, so the bow is what makes it read as a route. */
export function arc(a: [number, number], b: [number, number], n = 40): Array<[number, number]> {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const c: [number, number] = [(a[0] + b[0]) / 2 - dy * 0.2, (a[1] + b[1]) / 2 + dx * 0.2];
  const out: Array<[number, number]> = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n, u = 1 - t;
    out.push([u * u * a[0] + 2 * u * t * c[0] + t * t * b[0], u * u * a[1] + 2 * u * t * c[1] + t * t * b[1]]);
  }
  return out;
}

/** $48.2K, $1.3M, $950: money read across the room. */
export function compactMoney(cents: number): string {
  const d = cents / 100, a = Math.abs(d), sign = d < 0 ? '-' : '';
  if (a >= 1e6) return `${sign}$${(a / 1e6).toFixed(1)}M`;
  if (a >= 1e3) return `${sign}$${(a / 1e3).toFixed(1)}K`;
  return `${sign}$${Math.round(a)}`;
}
/** "now", "2m", "3h", "2d". */
export function shortAgo(iso: string, now = Date.now()): string {
  const m = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60000));
  return m < 1 ? 'now' : m < 60 ? `${m}m` : m < 1440 ? `${Math.round(m / 60)}h` : `${Math.round(m / 1440)}d`;
}

export const FLEET_STATUS: Record<FleetCar['status'], { label: string; colour: string }> = {
  on_rent: { label: 'On rent', colour: '#4ade80' }, available: { label: 'Available', colour: '#38bdf8' }, in_service: { label: 'In service', colour: '#fb923c' }
};

const TYPE_POINTS: Partial<Record<LeadType, [string, number]>> = {
  on_rent: ['On rent now', 40], booking: ['Booking confirmed', 40], request: ['Request sent', 35], lead: ['Form sent', 25], draft: ['Form started', 15]
};

/**
 * The score, 0 to 100: the sum of the points of the signals, capped. The signals: what the person did (the most advanced
 * step), a game played or its prize claimed, past rentals, a returning visitor, pages, time on the site, cars viewed,
 * on the site now, from an ad, and the strongest reasons of the Live visitors score (their points as set in Signal settings).
 */
export function signalsOf(p: RawPin): Signal[] {
  const f = p.facts ?? ({} as Facts), out: Signal[] = [];
  const t = TYPE_POINTS[p.type];
  if (t) out.push({ label: t[0], points: t[1] });
  if (f.claimed) out.push({ label: 'Claimed a game prize', points: 12 });
  else if (f.game || p.type === 'game') out.push({ label: 'Played a game', points: 8 });
  if (f.past > 0) out.push({ label: f.past === 1 ? 'Rented before' : `Rented ${f.past} times`, points: Math.min(20, 10 * f.past) });
  if (f.visit > 1) out.push({ label: `Visit ${f.visit}`, points: 8 });
  if (f.pages >= 10) out.push({ label: `${f.pages} pages`, points: 10 });
  else if (f.pages >= 4) out.push({ label: `${f.pages} pages`, points: 5 });
  const min = Math.floor((f.seconds ?? 0) / 60);
  if (min >= 10) out.push({ label: `${min} min on site`, points: 10 });
  else if (min >= 3) out.push({ label: `${min} min on site`, points: 5 });
  if (f.cars >= 3) out.push({ label: `Viewed ${f.cars} cars`, points: 8 });
  else if (f.cars > 0) out.push({ label: f.cars === 1 ? 'Viewed a car' : `Viewed ${f.cars} cars`, points: 4 });
  if (p.online) out.push({ label: 'On the site now', points: 6 });
  if (p.from_ad) out.push({ label: 'Came from an ad', points: 3 });
  for (const r of Array.isArray(f.reasons) ? f.reasons : []) {
    const w = Number(r.weight);
    if (Number.isFinite(w) && w > 0) out.push({ label: String(r.why || r.label).slice(0, 60), points: w, live: true });
  }
  return out.sort((a, b) => b.points - a.points || a.label.localeCompare(b.label));
}
export const scoreOf = (s: Signal[]) => Math.max(0, Math.min(100, Math.round(s.reduce((n, x) => n + x.points, 0))));
export const bandOf = (score: number): Pin['band'] => (score >= 60 ? 'hot' : score >= 30 ? 'warm' : 'cold');

/** "Maya Chen" as "Maya C."; "Visitor in Mississauga" when we do not know who it is. */
export function shortName(name: string | null): string | null {
  const parts = (name ?? '').trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return null;
  const a = parts[0] ?? '', z = parts[parts.length - 1] ?? '';
  const first = a.charAt(0).toUpperCase() + a.slice(1);
  return parts.length > 1 ? `${first} ${z.charAt(0).toUpperCase()}.` : first;
}
export function visitorLabel(city: string | null): string {
  return city ? `Visitor in ${city}` : 'Visitor';
}
/** The last 4 digits only: "ending 0199". */
export function maskPhone(phone: string | null): string | null {
  const d = (phone ?? '').replace(/\D/g, '');
  return d.length >= 4 ? `ending ${d.slice(-4)}` : null;
}

/** The view of one read: scored, and masked unless `details` (Admins on the normal page, after "Show details"). */
export function toView(raw: RawMap, details: boolean): MapView {
  const pins = (raw.pins ?? []).map((p): Pin => {
    const signals = signalsOf(p), score = scoreOf(signals);
    const known = shortName(p.name);
    return {
      id: p.id, type: p.type, types: p.types ?? [p.type], at: p.at, detail: p.detail, booking_number: p.booking_number, renter_id: p.renter_id, session_id: p.session_id,
      pickup_at: p.pickup_at ?? null, return_at: p.return_at ?? null,
      who: known ? (details ? (p.name ?? '').trim() : known) : visitorLabel(p.city), anonymous: !known,
      email: details ? p.email : null, phone: details ? p.phone : maskPhone(p.phone),
      city: p.city, lat: num(p.lat), lng: num(p.lng), precision: p.precision, online: !!p.online, device: p.device,
      score, band: bandOf(score), signals, car: p.car, masked: !details
    };
  });
  const hq = raw.hq && num(raw.hq.lat) !== null && num(raw.hq.lng) !== null ? { lat: num(raw.hq.lat)!, lng: num(raw.hq.lng)! } : null;
  return { at: raw.at, days: raw.days, cap: raw.cap, hq, kpi: raw.kpi, totals: raw.totals ?? {}, pins, fleet: raw.fleet ?? [], masked: !details };
}
const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && v !== '' && Number.isFinite(Number(v)) ? Number(v) : null);

/** A small stable number from an id (FNV-1a), for the spread and the angle. */
export function hash(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return h >>> 0;
}

export interface Placed { id: string; lng: number; lat: number }
/**
 * Pins that share a spot (the same 0.001 degree) go round it on a small circle, about 250 m out, a wider ring after 8;
 * a lone pin stays where it is. The order is by id, so a pin keeps its place from one refresh to the next.
 */
export function spread(points: Array<{ id: string; lng: number; lat: number }>): Placed[] {
  const groups = new Map<string, Array<{ id: string; lng: number; lat: number }>>();
  for (const p of points) {
    const k = `${p.lat.toFixed(3)},${p.lng.toFixed(3)}`;
    (groups.get(k) ?? groups.set(k, []).get(k)!).push(p);
  }
  const out: Placed[] = [];
  for (const g of groups.values()) {
    const one = g[0];
    if (!one) continue;
    if (g.length === 1) { out.push({ id: one.id, lng: one.lng, lat: one.lat }); continue; }
    g.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const turn = (hash(g[0]!.id) % 360) * (Math.PI / 180);
    g.forEach((p, i) => {
      const ring = Math.floor(i / 8), inRing = Math.min(8, g.length - ring * 8);
      const a = turn + (2 * Math.PI * (i % 8)) / inRing + ring * 0.4;
      const r = 0.0024 * (1 + ring * 0.7);
      // a degree of longitude is shorter than one of latitude this far north
      out.push({ id: p.id, lat: p.lat + r * Math.sin(a), lng: p.lng + (r * Math.cos(a)) / Math.cos((p.lat * Math.PI) / 180) });
    });
  }
  return out;
}

/** Counts for the legend: per type (every person, before the cap) and the pins not drawn (no position, or out of the area). */
export function tally(v: MapView, inArea: (lng: number, lat: number) => boolean) {
  let none = 0, outside = 0;
  for (const p of v.pins) {
    if (p.lat === null || p.lng === null) none++;
    else if (!inArea(p.lng, p.lat)) outside++;
  }
  const byType = Object.fromEntries(TYPES.map((t) => [t.type, Number(v.totals[t.type] ?? v.pins.filter((p) => p.type === t.type).length)])) as Record<LeadType, number>;
  const byStage = Object.fromEntries(STAGES.map((s) => [s.stage, s.types.reduce((n, t) => n + byType[t], 0)])) as Record<Stage, number>;
  return { byType, byStage, none, outside, shown: v.pins.length - none - outside };
}

/** The TV spotlight: the hottest leads first (a car photo first among equals), at most 8. */
export function spotlight(v: MapView, n = 8): Pin[] {
  return [...v.pins].sort((a, b) => b.score - a.score || Number(realPhoto(b)) - Number(realPhoto(a)) || (b.at > a.at ? 1 : b.at < a.at ? -1 : 0)).slice(0, n);
}

/** A listing photo of the car (not a sample drawing). */
export const realPhoto = (p: Pin) => !!p.car?.photo?.path && !p.car.photo.sample;

/** "now", "2 min ago", "3 h ago", "2 days ago". */
export function agoText(iso: string, now = Date.now()): string {
  const m = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60000));
  if (m < 1) return 'now';
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  const d = Math.round(h / 24);
  return d === 1 ? '1 day ago' : `${d} days ago`;
}
export const isNew = (iso: string, ms: number, now = Date.now()) => now - new Date(iso).getTime() < ms;

export const PRECISION_WORDS: Record<Exclude<Precision, null>, string> = {
  visit: 'Approximate, from the visit (about 1 km)', home_city: 'Centre of their home city', visit_city: 'Centre of the visit\'s city'
};
export const CAR_HOW: Record<string, string> = { on_rent: 'Renting', booking: 'Booked', request: 'Requested', previous: 'Rented last', viewed: 'Last viewed' };
