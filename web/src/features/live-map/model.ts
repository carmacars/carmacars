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
  name: string | null; email: string | null; phone: string | null; city: string | null; lat: number | null; lng: number | null; precision: Precision;
  online: boolean | null; device: string | null; from_ad: boolean; facts: Facts; car: MapCar | null;
}
export interface FleetCar { vehicle_id: string; code: string | null; name: string; lat: number; lng: number; heading: number | null; speed: number | null; status: 'on_rent' | 'available' | 'in_service'; updated_at: string; photo: CarPhoto | null }
export interface Kpi { active_now: number; requests_today: number; bookings_week: number; on_rent_now: number; collected_month_cents: number | null }
export interface RawMap { at: string; days: number; cap: number; live_minutes: number; kpi: Kpi; totals: Partial<Record<LeadType, number>>; pins: RawPin[]; fleet: FleetCar[] }

export interface Signal { label: string; points: number; live?: boolean }
export interface Pin {
  id: string; type: LeadType; types: LeadType[]; at: string; detail: string | null; booking_number: string | null; renter_id: string | null; session_id: string | null;
  who: string; anonymous: boolean; email: string | null; phone: string | null; city: string | null; lat: number | null; lng: number | null; precision: Precision;
  online: boolean; device: string | null; score: number; band: 'hot' | 'warm' | 'cold'; signals: Signal[]; car: MapCar | null; masked: boolean;
}
export interface MapView { at: string; days: number; cap: number; kpi: Kpi; totals: Partial<Record<LeadType, number>>; pins: Pin[]; fleet: FleetCar[]; masked: boolean }

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
      who: known ? (details ? (p.name ?? '').trim() : known) : visitorLabel(p.city), anonymous: !known,
      email: details ? p.email : null, phone: details ? p.phone : maskPhone(p.phone),
      city: p.city, lat: num(p.lat), lng: num(p.lng), precision: p.precision, online: !!p.online, device: p.device,
      score, band: bandOf(score), signals, car: p.car, masked: !details
    };
  });
  return { at: raw.at, days: raw.days, cap: raw.cap, kpi: raw.kpi, totals: raw.totals ?? {}, pins, fleet: raw.fleet ?? [], masked: !details };
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
  return { byType, none, outside, shown: v.pins.length - none - outside };
}

/** The TV spotlight: the hottest leads first (a car photo first among equals), at most 8. */
export function spotlight(v: MapView, n = 8): Pin[] {
  return [...v.pins].sort((a, b) => b.score - a.score || Number(!!b.car?.photo) - Number(!!a.car?.photo) || (b.at > a.at ? 1 : b.at < a.at ? -1 : 0)).slice(0, n);
}

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
