// Fleet tracking (migration 0400): what the database's one read (ops_read tracker_fleet) returns, each car's state in
// words, and demo mode (the simulator's positions, trips and alerts laid over the real cars, never written anywhere).
// Imports only the simulator: unit tested in Node (model.test.ts).
import { simAt, simFleet, simTrip } from './sim.ts';

export interface CarPhoto { path: string; variants?: Array<{ width: number; path: string }> | null; alt?: string; sample?: boolean }
export interface Pos { lat: number; lng: number; speed: number | null; heading: number | null; ignition: boolean | null; at: string; odometer: number | null;
  battery: number | null; fuel: number | null; power: boolean | null; outside_ontario?: boolean; outside_zone?: boolean }
export type TrackedCar = {
  vehicle_id: string; code: string | null; name: string; plate: string | null; status: string; mode: string | null; photo: CarPhoto | null;
  device: { id: string; serial: string; imei: string | null; firmware: string | null; installed_at: string | null; fee_from: string | null } | null;
  pos: Pos | null; trip: { started_at: string; km: number; max: number | null } | null;
  booking: { id: string; number: string; status: string; renter: string | null; pickup_at: string; return_at: string; overdue: boolean } | null;
  demo?: boolean;
};
export type AlertKind = 'speeding' | 'left_ontario' | 'left_zone' | 'overdue_driving' | 'battery_low' | 'unplugged' | 'offline';
export interface TrackerAlert { id: string; kind: AlertKind; title: string; detail: string | null; at: string; vehicle_id: string | null; booking_number: string | null;
  lat: number | null; lng: number | null; ack_at: string | null; ack_by: string | null; ack_note: string | null; demo?: boolean }
export interface BookingTrips { booking_id: string; number: string; status: string; renter: string | null; vehicle_id: string; vehicle: string; trips: number; km: number;
  max_speed: number | null; first: string; last: string; list: Array<{ id: string; started_at: string; ended_at: string; km: number; max: number | null }>; demo?: boolean }
export type Unpaired = { id: string; serial: string; imei: string | null; status: string; last_seen: string | null; battery: number | null; lat: number | null; lng: number | null };
export interface Settings { history_seconds: number; history_days: number; trip_days: number; speed_alert_kmh: number; battery_low_pct: number; overdue_grace_minutes: number;
  offline_hours: number; ontario_alert: boolean; zone_name: string | null; zone_lat: number | null; zone_lng: number | null; zone_radius_km: number | null; demo: boolean;
  key_set: boolean; key_hint: string | null; key_set_at: string | null }
export interface Fleet { at: string; admin: boolean; demo: boolean; settings: Settings; hq: { lat: number; lng: number } | null; cars: TrackedCar[]; unpaired: Unpaired[];
  alerts: TrackerAlert[]; open_alerts: number; bookings: BookingTrips[];
  counts: { cars: number; tracked: number; moving: number; parked: number; offline: number; on_rent: number } }

/** A report this old (or older) means the tracker is not reporting now. */
export const STALE_MS = 15 * 60_000;
export type State = 'moving' | 'idle' | 'parked' | 'offline' | 'none';
export const STATE: Record<State, { label: string; colour: string }> = {
  moving: { label: 'Moving', colour: '#4ade80' }, idle: { label: 'Engine on', colour: '#facc15' }, parked: { label: 'Parked', colour: '#38bdf8' },
  offline: { label: 'Not reporting', colour: '#fb923c' }, none: { label: 'No tracker', colour: '#94a3b8' }
};

export function stateOf(c: Pick<TrackedCar, 'device' | 'pos'>, now: number): State {
  if (!c.pos) return c.device ? 'offline' : 'none';
  if (now - new Date(c.pos.at).getTime() > STALE_MS) return 'offline';
  if ((c.pos.speed ?? 0) >= 3) return 'moving';
  return c.pos.ignition ? 'idle' : 'parked';
}

/** "now", "4 min", "3 h", "2 d". */
export function ago(iso: string | null | undefined, now: number): string {
  if (!iso) return '';
  const m = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60000));
  return m < 1 ? 'now' : m < 60 ? `${m} min` : m < 1440 ? `${Math.round(m / 60)} h` : `${Math.round(m / 1440)} d`;
}
/** One line for the car's state: "72 km/h · 401", "Parked 12 min", "Not reporting for 3 h". */
export function stateLine(c: TrackedCar, now: number): string {
  const s = stateOf(c, now);
  if (s === 'none') return 'No tracker yet';
  if (!c.pos) return 'Waiting for its first report';
  if (s === 'offline') return `Not reporting for ${ago(c.pos.at, now)}`;
  if (s === 'moving') return `${Math.round(c.pos.speed ?? 0)} km/h${c.trip ? ` · ${c.trip.km} km this trip` : ''}`;
  const seen = ago(c.pos.at, now);
  return s === 'idle' ? `Engine on, still · ${seen}` : `Parked · last report ${seen === 'now' ? 'just now' : `${seen} ago`}`;
}
/** Toronto time, short: "Sat 3:40 pm". */
export function when(iso: string | null | undefined): string {
  return iso ? new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', weekday: 'short', hour: 'numeric', minute: '2-digit' }) : '';
}

export const ALERT: Record<AlertKind, { label: string; tone: 'red' | 'amber' | 'grey' }> = {
  speeding: { label: 'Speeding', tone: 'red' }, left_ontario: { label: 'Left Ontario', tone: 'red' }, left_zone: { label: 'Left the zone', tone: 'amber' },
  overdue_driving: { label: 'Driving after return time', tone: 'red' }, battery_low: { label: 'Low tracker battery', tone: 'amber' },
  unplugged: { label: 'Unplugged', tone: 'red' }, offline: { label: 'Not reporting', tone: 'grey' }
};

/** A circle as a ring of points (for the geofence on the map). */
export function circle(lat: number, lng: number, radiusKm: number, n = 64): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  const dLat = radiusKm / 110.574, dLng = radiusKm / (111.32 * Math.cos((lat * Math.PI) / 180));
  for (let i = 0; i <= n; i++) { const a = (i / n) * 2 * Math.PI; out.push([lng + dLng * Math.cos(a), lat + dLat * Math.sin(a)]); }
  return out;
}

const DEMO_NAMES = ['2024 Toyota Corolla', '2023 Honda Civic', '2022 Hyundai Elantra', '2024 Kia Sportage', '2021 Volkswagen Jetta', '2023 Mazda CX-5'];
/**
 * Demo mode: every car without a real position drives the simulator's route (the real cars, their photos and bookings, so
 * the screen looks as it will); with no cars at all, six made-up ones. The trips per booking and three alerts (speeding,
 * low battery, unplugged) come from the same cars. Nothing is written; every demo row is marked demo.
 */
export function withDemo(f: Fleet, now: number): Fleet {
  if (!f.demo) return f;
  const base: TrackedCar[] = f.cars.length ? f.cars : DEMO_NAMES.map((name, i) => ({
    vehicle_id: `demo-${i + 1}`, code: `CC-DEMO${i + 1}`, name, plate: null, status: 'available', mode: null, photo: null, device: null, pos: null, trip: null, booking: null }));
  const need = base.filter((c) => !c.pos);
  const sims = simFleet(need.map((c) => c.vehicle_id), f.settings.speed_alert_kmh);
  const simBy = new Map(need.map((c, i) => [c.vehicle_id, sims[i]!]));
  const at = new Date(now).toISOString();
  const cars = base.map((c): TrackedCar => {
    const sim = simBy.get(c.vehicle_id);
    if (!sim) return c;
    const s = simAt(sim, now);
    return { ...c, demo: true, device: c.device ?? { id: `demo-${sim.device}`, serial: sim.device, imei: null, firmware: 'demo', installed_at: null, fee_from: null },
      pos: { lat: s.lat, lng: s.lng, speed: s.speed, heading: s.heading, ignition: s.ignition, at, odometer: s.odometer, battery: s.battery, fuel: s.fuel, power: s.power },
      trip: simTrip(sim, now) };
  });
  const demoCars = cars.filter((c) => c.demo);
  const alerts: TrackerAlert[] = [];
  const add = (c: TrackedCar | undefined, kind: AlertKind, title: string, detail: string, minsAgo: number) => {
    if (!c?.pos) return;
    alerts.push({ id: `demo-${kind}-${c.vehicle_id}`, kind, title, detail, at: new Date(now - minsAgo * 60_000).toISOString(), vehicle_id: c.vehicle_id,
      booking_number: c.booking?.number ?? null, lat: c.pos.lat, lng: c.pos.lng, ack_at: null, ack_by: null, ack_note: null, demo: true });
  };
  const label = (c: TrackedCar | undefined) => (c ? `${c.name}${c.code ? ` (${c.code})` : ''}` : '');
  add(demoCars[1], 'speeding', `Speeding: ${label(demoCars[1])} at ${f.settings.speed_alert_kmh + 8} km/h`, `Over the ${f.settings.speed_alert_kmh} km/h alert level.`, 6);
  add(demoCars[2], 'battery_low', `Tracker battery low: ${label(demoCars[2])}`, `${demoCars[2]?.pos?.battery ?? 14}%.`, 42);
  add(demoCars[4], 'unplugged', `Tracker unplugged: ${label(demoCars[4])}`, 'The tracker lost the car\'s power. It runs on its own battery.', 95);
  const trips: BookingTrips[] = demoCars.filter((c) => c.booking?.status === 'on_rent' && c.trip).map((c) => ({
    booking_id: c.booking!.id, number: c.booking!.number, status: c.booking!.status, renter: c.booking!.renter, vehicle_id: c.vehicle_id, vehicle: c.name,
    trips: 1, km: c.trip!.km, max_speed: c.trip!.max, first: c.trip!.started_at, last: at, demo: true,
    list: [{ id: `demo-trip-${c.vehicle_id}`, started_at: c.trip!.started_at, ended_at: at, km: c.trip!.km, max: c.trip!.max }] }));
  const moving = cars.filter((c) => stateOf(c, now) === 'moving').length, parked = cars.filter((c) => ['parked', 'idle'].includes(stateOf(c, now))).length;
  return { ...f, cars, alerts: [...alerts, ...f.alerts], open_alerts: f.open_alerts + alerts.length, bookings: [...trips, ...f.bookings],
    counts: { ...f.counts, cars: cars.length, tracked: cars.filter((c) => c.device).length, moving, parked, offline: cars.filter((c) => stateOf(c, now) === 'offline').length } };
}

/** Cars on the map: on rent first, then moving, then the rest, by name. */
export function sorted(cars: TrackedCar[], now: number): TrackedCar[] {
  const rank = (c: TrackedCar) => (c.booking?.status === 'on_rent' ? 0 : stateOf(c, now) === 'moving' ? 1 : c.pos ? 2 : 3);
  return [...cars].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
}
