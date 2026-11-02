import { test } from 'node:test';
import assert from 'node:assert/strict';
import { circle, sorted, stateLine, stateOf, withDemo, type Fleet, type TrackedCar } from './model.ts';

const NOW = Date.UTC(2026, 10, 1, 18, 0, 0);
const iso = (minsAgo: number) => new Date(NOW - minsAgo * 60_000).toISOString();
const car = (over: Partial<TrackedCar>): TrackedCar => ({ vehicle_id: 'v1', code: 'CC-1', name: '2024 Toyota Corolla', plate: null, status: 'available', mode: 'managed', photo: null,
  device: { id: 'd1', serial: 'TRK-1', imei: null, firmware: null, installed_at: null, fee_from: null }, pos: null, trip: null, booking: null, ...over });
const pos = (speed: number, ignition: boolean, minsAgo = 1) => ({ lat: 43.65, lng: -79.38, speed, heading: 90, ignition, at: iso(minsAgo), odometer: 1000, battery: 90, fuel: 50, power: true });

test('a car\'s state: moving, engine on, parked, not reporting after 15 minutes, no tracker', () => {
  assert.equal(stateOf(car({ pos: pos(72, true) }), NOW), 'moving');
  assert.equal(stateOf(car({ pos: pos(0, true) }), NOW), 'idle');
  assert.equal(stateOf(car({ pos: pos(0, false) }), NOW), 'parked');
  assert.equal(stateOf(car({ pos: pos(50, true, 16) }), NOW), 'offline');
  assert.equal(stateOf(car({ device: null }), NOW), 'none');
  assert.equal(stateLine(car({ pos: pos(72, true), trip: { started_at: iso(10), km: 12.4, max: 98 } }), NOW), '72 km/h · 12.4 km this trip');
  assert.equal(stateLine(car({ pos: pos(0, false, 180) }), NOW), 'Not reporting for 3 h');
});

test('on rent first, then moving, then by name', () => {
  const a = car({ vehicle_id: 'a', name: 'B car', pos: pos(0, false) }), b = car({ vehicle_id: 'b', name: 'A car', pos: pos(60, true) }),
    c = car({ vehicle_id: 'c', name: 'Z car', pos: pos(0, false), booking: { id: 'x', number: 'CC-1', status: 'on_rent', renter: 'R', pickup_at: iso(60), return_at: iso(-60), overdue: false } });
  assert.deepEqual(sorted([a, b, c], NOW).map((x) => x.vehicle_id), ['c', 'b', 'a']);
});

const fleet = (cars: TrackedCar[], demo: boolean): Fleet => ({ at: iso(0), admin: true, demo, hq: null, cars, unpaired: [], alerts: [], open_alerts: 0, bookings: [],
  counts: { cars: cars.length, tracked: 0, moving: 0, parked: 0, offline: 0, on_rent: 0 },
  settings: { history_seconds: 60, history_days: 90, trip_days: 365, speed_alert_kmh: 140, battery_low_pct: 20, overdue_grace_minutes: 15, offline_hours: 6, ontario_alert: true,
    zone_name: null, zone_lat: null, zone_lng: null, zone_radius_km: null, demo, key_set: false, key_hint: null, key_set_at: null } });

test('demo mode: off changes nothing; on, cars without a position drive, a real position is kept, alerts are marked demo', () => {
  const real = car({ vehicle_id: 'real', pos: pos(0, false) });
  const f = fleet([real, ...['a', 'b', 'c', 'd', 'e'].map((id) => car({ vehicle_id: id, device: null }))], true);
  const off = { ...f, demo: false };
  assert.equal(withDemo(off, NOW), off);
  const d = withDemo(f, NOW);
  assert.equal(d.cars.find((c) => c.vehicle_id === 'real')!.demo, undefined);
  assert.ok(d.cars.filter((c) => c.demo).every((c) => c.pos && c.device));
  assert.deepEqual(d.alerts.map((a) => a.kind).sort(), ['battery_low', 'speeding', 'unplugged']);
  assert.ok(d.alerts.every((a) => a.demo));
});

test('demo mode with no cars: six made-up cars', () => {
  assert.equal(withDemo(fleet([], true), NOW).cars.length, 6);
});

test('the geofence ring closes on itself', () => {
  const r = circle(43.65, -79.38, 30);
  assert.deepEqual(r[0], r[r.length - 1]);
  assert.ok(Math.abs(r[16]![1] - (43.65 + 30 / 110.574)) < 1e-9);
});
