import type { Intent } from '../intent/model.ts';
// The Live map (migration 0242): what the database's one read (admin_read live_map) returns, and what the website works
// out from it: the score and its signals, the names, the contact details only when asked for (Release 26), where each pin goes (spread a little when several
// share a spot, the same way on every refresh), the counts and the spotlight. Unit tested in Node (imports only roles.ts).
import { cleanRoles, notRenterOnly } from './roles.ts';

export type LeadType = 'session' | 'game' | 'draft' | 'lead' | 'request' | 'booking' | 'on_rent' | 'previous';
export type Precision = 'visit' | 'home_city' | 'visit_city' | null;

export interface CarPhoto { path: string; variants?: Array<{ width: number; path: string; format?: string }> | null; alt?: string; sample?: boolean }
export interface MapCar { id: string; code: string | null; name: string; daily_cents: number | null; photo: CarPhoto | null; how: string }
export interface LiveReason { kind?: string; label: string; why?: string; weight: number }
export interface Facts { pages: number; seconds: number; cars: number; visit: number; past: number; game: boolean; claimed: boolean; live_score: number | null; reasons: LiveReason[] }
export interface RawPin {
  id: string; type: LeadType; types: LeadType[]; at: string; detail: string | null; booking_number: string | null; renter_id: string | null; session_id: string | null;
  pickup_at?: string | null; return_at?: string | null;
  /** r35 part C (1506): the renter's intent (score, label, signals) */
  intent?: Intent | null;
  name: string | null; email: string | null; phone: string | null; city: string | null; lat: number | null; lng: number | null; precision: Precision;
  online: boolean | null; device: string | null; from_ad: boolean; facts: Facts; car: MapCar | null;
  /** 0470: what the person is to us (owner, renter, ...) and their owners row */
  roles?: string[] | null; owner_id?: string | null;
}
export interface FleetCar { vehicle_id: string; code: string | null; name: string; lat: number; lng: number; heading: number | null; speed: number | null; status: 'on_rent' | 'available' | 'in_service'; updated_at: string; photo: CarPhoto | null }
export interface Kpi { active_now: number; requests_today: number; requests_yesterday?: number; bookings_week: number; on_rent_now: number; collected_month_cents: number | null }
/** 1064: staff working now and the week's Sales leaderboard (on the figures' layer) */
export interface Working { name: string; role: string; since: string }
export interface Leader { name: string; bookings: number }
/** 1068: a booking confirmed in the last 15 minutes: the celebration on the map */
export interface Celebration { booking_number: string; at: string; car: string | null; sales: string | null }
export interface RawMap { working?: Working[]; leaderboard?: Leader[]; celebrations?: Celebration[]; at: string; days: number; cap: number; live_minutes: number; hq?: { lat: number; lng: number } | null; kpi: Kpi; totals: Partial<Record<LeadType, number>>; pins: RawPin[]; fleet: FleetCar[];
  /** 1080: the layers that could not be read (kpi, pins, fleet, roles); the others are drawn */
  failed?: string[] }

/** 1080: the map's three layers, each read on its own (admin_read live_map {part}), so a slow or failing one leaves the others. */
export const MAP_PARTS = ['kpi', 'pins', 'fleet'] as const;
export type MapPart = (typeof MAP_PARTS)[number];
const PART_KEYS: Record<MapPart, Array<keyof RawMap>> = { kpi: ['kpi', 'working', 'leaderboard', 'celebrations'], pins: ['pins', 'totals'], fleet: ['fleet'] };
/** One answer from the layers' answers: each layer's own keys from its answer; a layer that failed (refused, timed out, or
 *  named in the database's "failed") is listed in failed and drawn empty. Throws only when every layer failed. */
export function mergeParts(parts: Array<{ part: MapPart; ok: true; value: RawMap } | { part: MapPart; ok: false; error: unknown }>): RawMap {
  const good = parts.filter((x): x is { part: MapPart; ok: true; value: RawMap } => x.ok && !!x.value);
  if (!good.length) { const e = parts.find((x) => !x.ok) as { error: unknown } | undefined; throw e?.error instanceof Error ? e.error : new Error('The map could not be read'); }
  const base = good[0]!.value;
  const out: RawMap = { at: base.at, days: base.days, cap: base.cap, live_minutes: base.live_minutes, hq: base.hq ?? null,
    kpi: { active_now: 0, requests_today: 0, bookings_week: 0, on_rent_now: 0, collected_month_cents: null }, totals: {}, pins: [], fleet: [] };
  const failed = new Set<string>();
  for (const x of parts) {
    if (!x.ok) { failed.add(x.part); continue; }
    for (const k of PART_KEYS[x.part]) if (x.value[k] !== undefined) (out as unknown as Record<string, unknown>)[k] = x.value[k];
    for (const f of x.value.failed ?? []) if (f === 'roles' || f === x.part) failed.add(f);
    // 0400: the demo flag rides on every answer
    const demo = (x.value as RawMap & { tracker_demo?: boolean }).tracker_demo;
    if (demo !== undefined) (out as RawMap & { tracker_demo?: boolean }).tracker_demo = demo;
  }
  out.failed = [...MAP_PARTS.filter((p) => failed.has(p)), ...(failed.has('roles') ? ['roles'] : [])];
  return out;
}
/** The note under a map with a layer missing: "Couldn't load the visitors and the fleet." */
export function failedNote(failed: string[] | undefined): string {
  const w: Record<string, string> = { kpi: 'the numbers at the top', pins: 'the visitors and leads', fleet: 'the fleet', roles: 'who each person is to us' };
  const parts = (failed ?? []).map((f) => w[f]).filter((x): x is string => !!x);
  if (!parts.length) return '';
  const list = parts.length === 1 ? parts[0] : `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`;
  return `Couldn't load ${list}. Trying again in 30 seconds.`;
}

export interface Signal { label: string; points: number; live?: boolean }
export interface Pin {
  id: string; type: LeadType; types: LeadType[]; at: string; detail: string | null; booking_number: string | null; renter_id: string | null; session_id: string | null;
  pickup_at: string | null; return_at: string | null;
  who: string; anonymous: boolean; email: string | null; phone: string | null; city: string | null; lat: number | null; lng: number | null; precision: Precision;
  online: boolean; device: string | null; score: number; band: 'hot' | 'warm' | 'cold'; signals: Signal[]; car: MapCar | null;
  roles: string[]; owner_id: string | null;
  /** Release 26: the full name for the detail card (null for an anonymous visitor); `who` is the short label for pins and lists. */
  name: string | null;
  /** seconds on the site (the visit's), for the card's time line */
  seconds: number | null;
  /** r35 part C (1506): the renter's intent */
  intent: Intent | null;
}
export interface MapView { working: Working[]; leaderboard: Leader[]; celebrations: Celebration[]; at: string; days: number; cap: number; hq: { lat: number; lng: number } | null; kpi: Kpi; totals: Partial<Record<LeadType, number>>; pins: Pin[]; fleet: FleetCar[];
  /** Release 26: phones and emails are in this answer ("Show contact" on); without it they are never sent. */
  contact: boolean;
  /** 0400: the fleet layer is Fleet tracking's demo mode (simulated cars) */ fleet_demo?: boolean;
  /** 1080: the layers that could not be read this time */ failed?: string[] }

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
/** Who gets a photo pin: on rent, booked, or a hot lead (score 60 or more, isLead), with a car to show; at most `max`, the most advanced and hottest first. */
export function photoPins(pins: Pin[], max = 60): Set<string> {
  const want = pins.filter((p) => !!p.car && (p.type === 'on_rent' || p.type === 'booking' || (p.band === 'hot' && isLead(p))));
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
/**
 * The view of one read, scored. Names always (Release 26, the owner: the leads "should show names"): the first name and
 * last initial as `who` for pins and lists, the full name as `name` for the detail card, "Visitor in Mississauga" for an
 * anonymous visitor. Phones and emails only with `contact` ("Show contact"); otherwise they are not in the answer at all,
 * not even in part.
 */
export function toView(raw: RawMap, contact: boolean): MapView {
  const pins = (raw.pins ?? []).map((p): Pin => {
    const signals = signalsOf(p), score = scoreOf(signals);
    const known = shortName(p.name);
    return {
      id: p.id, type: p.type, types: p.types ?? [p.type], at: p.at, detail: p.detail, booking_number: p.booking_number, renter_id: p.renter_id, session_id: p.session_id,
      pickup_at: p.pickup_at ?? null, return_at: p.return_at ?? null,
      who: known ?? visitorLabel(p.city), anonymous: !known, name: known ? (p.name ?? '').trim().replace(/\s+/g, ' ') : null,
      email: contact ? p.email || null : null, phone: contact ? p.phone || null : null,
      city: p.city, lat: num(p.lat), lng: num(p.lng), precision: p.precision, online: !!p.online, device: p.device,
      score, band: bandOf(score), signals, car: p.car, seconds: num(p.facts?.seconds),
      roles: Array.isArray(p.roles) ? p.roles : [], owner_id: p.owner_id ?? null, intent: p.intent ?? null
    };
  });
  const hq = raw.hq && num(raw.hq.lat) !== null && num(raw.hq.lng) !== null ? { lat: num(raw.hq.lat)!, lng: num(raw.hq.lng)! } : null;
  return { working: raw.working ?? [], leaderboard: raw.leaderboard ?? [], celebrations: raw.celebrations ?? [], at: raw.at, days: raw.days, cap: raw.cap, hq, kpi: raw.kpi, totals: raw.totals ?? {}, pins, fleet: raw.fleet ?? [], contact, failed: raw.failed ?? [] };
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

/**
 * A lead, not a rental (Release 26, the owner on a renter in "Hottest lead": "that's not a lead, that's a rental"): a
 * game player, a form started or sent, a request, a visitor on the site, or a past renter back browsing. Never someone
 * on rent or with a confirmed booking still to come (as their stage or any of their others), nor a request whose offer
 * they already accepted and are paying for ("Awaiting payment").
 */
export function isLead(p: Pick<Pin, 'type' | 'types' | 'detail'> & { roles?: string[] }): boolean {
  // 0470: an owner, partner, investor or staff member who is not also a renter is not a renter lead
  if (notRenterOnly(p.roles)) return false;
  if (p.type === 'on_rent' || p.type === 'booking') return false;
  if ((p.types ?? []).some((t) => t === 'on_rent' || t === 'booking')) return false;
  if (p.type === 'request' && /^Awaiting payment/i.test(p.detail ?? '')) return false;
  return true;
}

/** The TV's "Hottest lead": leads only (isLead), the highest score first (a car photo first among equals), at most 8; none
 * when nobody qualifies, never a renter instead. */
export function spotlight(v: MapView, n = 8): Pin[] {
  return v.pins.filter((p) => isLead(p) && p.score > 0).sort((a, b) => b.score - a.score || Number(realPhoto(b)) - Number(realPhoto(a)) || (b.at > a.at ? 1 : b.at < a.at ? -1 : 0)).slice(0, n);
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

export interface Box { id: string; x: number; y: number; w: number; h: number; /** home base: never moves, the others make room round it */ fixed?: boolean }
/**
 * Photo pins that would cover each other on screen move apart (Release 26): each overlapping pair is pushed apart along
 * the axis that needs the least movement, a fixed box (home base) never moves, and the rest stay as close to their spot
 * as they can, so a leader line shows where each one belongs. Pixels in, pixels out; the same input gives the same
 * answer (pins at one spot fan out by id). `gap` is the clear space kept between two pins.
 */
export function separate(boxes: Box[], gap = 6, rounds = 120): Map<string, { x: number; y: number }> {
  const b = [...boxes].sort((p, q) => (p.id < q.id ? -1 : p.id > q.id ? 1 : 0)).map((p) => ({ ...p }));
  // pins on one spot (a city's middle, for home-city leads) first make a tidy block of rows centred on it, so they
  // read as one group rather than a line pushed out in one direction
  const done = new Set<number>();
  for (let i = 0; i < b.length; i++) {
    const p = b[i]!;
    if (p.fixed || done.has(i)) continue;
    const same = [i];
    for (let j = i + 1; j < b.length; j++) { const q = b[j]!; if (!q.fixed && !done.has(j) && Math.hypot(q.x - p.x, q.y - p.y) < Math.min(p.w, p.h) * 0.5) same.push(j); }
    if (same.length < 2) continue;
    const cols = Math.ceil(Math.sqrt(same.length)), rows = Math.ceil(same.length / cols), cx = p.x, cy = p.y;
    same.forEach((j, n) => {
      const q = b[j]!, row = Math.floor(n / cols), inRow = Math.min(cols, same.length - row * cols), col = n % cols;
      q.x = cx + (col - (inRow - 1) / 2) * (q.w + gap);
      q.y = cy + (row - (rows - 1) / 2) * (q.h + gap);
      done.add(j);
    });
  }
  for (let r = 0; r < rounds; r++) {
    let moved = false;
    for (let i = 0; i < b.length; i++) for (let j = i + 1; j < b.length; j++) {
      const p = b[i]!, q = b[j]!;
      if (p.fixed && q.fixed) continue;
      let dx = q.x - p.x, dy = q.y - p.y;
      const ox = (p.w + q.w) / 2 + gap - Math.abs(dx), oy = (p.h + q.h) / 2 + gap - Math.abs(dy);
      if (ox <= 0.01 || oy <= 0.01) continue;
      moved = true;
      // the same spot: fan out by order round the circle, so two, three or more spread evenly
      if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) { const a = (hash(`${p.id}|${q.id}`) % 360) * (Math.PI / 180); dx = Math.cos(a); dy = Math.sin(a); }
      const sp = p.fixed ? 0 : q.fixed ? 1 : 0.5, sq = 1 - sp;
      // along the cheaper axis (relative to the two boxes' size on it)
      if (ox / (p.w + q.w) < oy / (p.h + q.h)) {
        const s = Math.sign(dx) || 1;
        p.x -= s * ox * sp; q.x += s * ox * sq;
      } else {
        const s = Math.sign(dy) || 1;
        p.y -= s * oy * sp; q.y += s * oy * sq;
      }
    }
    if (!moved) break;
  }
  return new Map(b.map((p) => [p.id, { x: p.x, y: p.y }]));
}

/** A view with the phones and emails taken out: the moment "Show contact" is turned off, before the next read. */
export function withoutContact(v: MapView): MapView {
  return { ...v, contact: false, pins: v.pins.map((p) => ({ ...p, email: null, phone: null })) };
}

/** Where the detail card's link goes in Admin: the booking, else the renter, else Live visitors (a visit), else the leads
 * page searched by the name (a form or a game with no renter yet). */
export function adminHref(p: Pick<Pin, 'booking_number' | 'renter_id' | 'session_id' | 'name' | 'type'> & { roles?: string[]; owner_id?: string | null }): { href: string; label: string } {
  if (p.booking_number) return { href: `/admin/bookings/${encodeURIComponent(p.booking_number)}`, label: `Open booking ${p.booking_number}` };
  // 0470: an owner (not also a renter) opens the owner's page, never "the renter"
  if (p.owner_id && cleanRoles(p.roles).includes('owner') && !cleanRoles(p.roles).includes('renter')) return { href: `/admin/owners/${encodeURIComponent(p.owner_id)}`, label: 'Open the owner' };
  if (p.renter_id && (!p.roles?.length || cleanRoles(p.roles).includes('renter'))) return { href: `/admin/renters/${encodeURIComponent(p.renter_id)}`, label: 'Open the renter' };
  if (p.type === 'session' || (p.session_id && !p.name)) return { href: '/admin/visitors', label: 'Open in Visitors' };
  return { href: p.name ? `/admin/leads?q=${encodeURIComponent(p.name)}` : '/admin/leads', label: p.roles?.length && notRenterOnly(p.roles) ? 'Open in Leads' : 'Open in Renter leads' };
}

/** Where the detail card's link goes in the staff portal (r27 consolidation): the booking, else the renter found by name
 * (Find a renter), else nothing: staff have no owner or lead pages of Admin's. */
export function staffHref(p: Pick<Pin, 'booking_number' | 'renter_id' | 'name' | 'type'> & { roles?: string[] }): { href: string; label: string } | null {
  if (p.booking_number) return { href: `/staff/bookings/${encodeURIComponent(p.booking_number)}`, label: `Open booking ${p.booking_number}` };
  if (p.renter_id && p.name && (!p.roles?.length || cleanRoles(p.roles).includes('renter'))) return { href: `/staff/renters?q=${encodeURIComponent(p.name)}`, label: 'Find the renter' };
  return null;
}

/** "12 min on the site", "on the site now", "seen 3h ago": the detail card's time line. */
export function timeLine(p: Pick<Pin, 'online' | 'at' | 'seconds'>, now = Date.now()): string {
  const on = p.seconds && p.seconds >= 60 ? `${Math.round(p.seconds / 60)} min on the site` : null;
  if (p.online) return on ? `On the site now, ${on}` : 'On the site now';
  return [on, `last seen ${shortAgo(p.at, now) === 'now' ? 'just now' : `${shortAgo(p.at, now)} ago`}`].filter(Boolean).join(', ');
}

/** Web Mercator, as MapLibre projects (0 to 1 across the world; the Canvas map, canvas.ts, multiplies by 512 x 2^zoom). */
export const mx = (lng: number) => (lng + 180) / 360;
export const my = (lat: number) => (1 - Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360)) / Math.PI) / 2;

// ---------------------------------------------------------------- clusters (Release 27)
export interface ClusterIn { id: string; lng: number; lat: number; hot: boolean; score: number; colour: string }
export interface Cluster { key: string; lng: number; lat: number; n: number; ids: string[]; colour: string; hot: boolean; top: string; score: number }
/**
 * Pins that crowd each other at this zoom (within `radius` screen pixels) become one count bubble, the same on the WebGL
 * and the Canvas map: the hottest first take the others that sit near them, so the bubble's place is the middle of its
 * members and its colour is its hottest member's. A lone pin stays a pin. The same input gives the same answer.
 * `world` is the size of the world in pixels at this zoom (512 * 2^zoom).
 */
export function clusterPins(pts: ClusterIn[], world: number, radius: number): { singles: ClusterIn[]; clusters: Cluster[] } {
  if (radius <= 0) return { singles: [...pts], clusters: [] };
  const order = [...pts].sort((a, b) => Number(b.hot) - Number(a.hot) || b.score - a.score || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const px = (p: ClusterIn) => [mx(p.lng) * world, my(p.lat) * world] as const;
  const grid = new Map<string, number[]>();
  const cell = (x: number, y: number) => `${Math.floor(x / radius)},${Math.floor(y / radius)}`;
  order.forEach((p, i) => { const [x, y] = px(p), k = cell(x, y); (grid.get(k) ?? grid.set(k, []).get(k)!).push(i); });
  const taken = new Array<boolean>(order.length).fill(false);
  const singles: ClusterIn[] = [], clusters: Cluster[] = [];
  order.forEach((p, i) => {
    if (taken[i]) return;
    taken[i] = true;
    const [x, y] = px(p), near: number[] = [];
    const cx = Math.floor(x / radius), cy = Math.floor(y / radius);
    for (let gx = cx - 1; gx <= cx + 1; gx++) for (let gy = cy - 1; gy <= cy + 1; gy++) for (const j of grid.get(`${gx},${gy}`) ?? []) {
      if (taken[j]) continue;
      const [qx, qy] = px(order[j]!);
      if (Math.hypot(qx - x, qy - y) <= radius) near.push(j);
    }
    if (!near.length) { singles.push(p); return; }
    near.forEach((j) => { taken[j] = true; });
    const members = [p, ...near.map((j) => order[j]!)];
    clusters.push({ key: members.map((m) => m.id).sort()[0]! + '+' + members.length, n: members.length, ids: members.map((m) => m.id),
      lng: members.reduce((a, m) => a + m.lng, 0) / members.length, lat: members.reduce((a, m) => a + m.lat, 0) / members.length,
      colour: p.colour, hot: members.some((m) => m.hot), top: p.id, score: p.score });
  });
  // bubbles (and pins) whose middles are still closer than the radius would draw on top of each other: join them, until none are
  const d = (a: { lng: number; lat: number }, b: { lng: number; lat: number }) => Math.hypot((mx(a.lng) - mx(b.lng)) * world, (my(a.lat) - my(b.lat)) * world);
  for (let again = true; again;) {
    again = false;
    clusters.sort((a, b) => b.n - a.n || (a.key < b.key ? -1 : 1));
    for (let i = 0; i < clusters.length && !again; i++) {
      const a = clusters[i]!;
      for (let j = i + 1; j < clusters.length && !again; j++) {
        const b = clusters[j]!;
        if (d(a, b) > radius) continue;
        const n = a.n + b.n, top = a.score >= b.score ? a : b;
        clusters[i] = { key: [...a.ids, ...b.ids].sort()[0]! + '+' + n, n, ids: [...a.ids, ...b.ids], lng: (a.lng * a.n + b.lng * b.n) / n, lat: (a.lat * a.n + b.lat * b.n) / n,
          colour: top.colour, hot: a.hot || b.hot, top: top.top, score: top.score };
        clusters.splice(j, 1); again = true;
      }
      for (let j = 0; j < singles.length && !again; j++) {
        const q = singles[j]!;
        if (d(a, q) > radius) continue;
        const n = a.n + 1, top = a.score >= q.score ? { colour: a.colour, top: a.top, score: a.score } : { colour: q.colour, top: q.id, score: q.score };
        clusters[i] = { key: [...a.ids, q.id].sort()[0]! + '+' + n, n, ids: [...a.ids, q.id], lng: (a.lng * a.n + q.lng) / n, lat: (a.lat * a.n + q.lat) / n, hot: a.hot || q.hot, ...top };
        singles.splice(j, 1); again = true;
      }
    }
  }
  return { singles, clusters };
}
/** The lowest zoom (in half steps, up to `max`) at which these pins no longer make one bubble, or null when they sit on one
 * spot and never will (then the bubble opens as a ring of pins instead). */
export function splitZoom(pts: ClusterIn[], from: number, max: number, radiusAt: (zoom: number) => number): number | null {
  for (let z = Math.floor(from * 2) / 2 + 0.5; z <= max + 1e-9; z += 0.5) {
    const r = clusterPins(pts, 512 * 2 ** z, radiusAt(z));
    if (r.clusters.length === 0 || r.singles.length + r.clusters.length > 1) return z;
  }
  return null;
}
/** Where a bubble's members go when it is opened on the spot: on a circle round its middle (a spiral past 8), pixel offsets. */
export function spiderOffsets(n: number, r0 = 34): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  for (let i = 0; i < n; i++) {
    const ring = Math.floor(i / 8), inRing = Math.min(8, n - ring * 8), a = -Math.PI / 2 + (2 * Math.PI * (i % 8)) / inRing + ring * 0.35, r = r0 * (1 + ring * 0.8);
    out.push([Math.cos(a) * r, Math.sin(a) * r]);
  }
  return out;
}

/** 1068: the celebration's toast: the car and who gets the Sales credit. */
export function celebrationText(c: Celebration): string {
  return `Booking confirmed${c.car ? `: ${c.car}` : ''}${c.sales ? `. Sales: ${c.sales}` : ''}`;
}
