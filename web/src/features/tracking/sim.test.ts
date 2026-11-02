import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ROUTES, km, simAt, simFleet, simPoints, simTrip } from './sim.ts';

const T0 = Date.UTC(2026, 10, 1, 15, 0, 0);

test('the same keys give the same fleet, and every car is somewhere in the GTA', () => {
  const a = simFleet(['car-a', 'car-b', 'car-c', 'car-d', 'car-e', 'car-f']), b = simFleet(['car-a', 'car-b', 'car-c', 'car-d', 'car-e', 'car-f']);
  assert.deepEqual(a, b);
  for (const c of a) {
    const s = simAt(c, T0);
    assert.ok(s.lat > 43.2 && s.lat < 44.3 && s.lng > -80.1 && s.lng < -78.6, `${c.key} at ${s.lat},${s.lng}`);
  }
});

test('a car moves along its highway at about its speed, and parks for 4 minutes in every 24', () => {
  const [c] = simFleet(['only']);
  const states = Array.from({ length: 24 * 6 }, (_, i) => simAt(c!, T0 + i * 10_000));
  const parked = states.filter((s) => !s.ignition).length;
  assert.equal(parked, 4 * 6);
  // one minute of driving covers about speed / 60 km (the route may turn back at its end)
  const t = states.findIndex((s, i) => s.ignition && states[i + 6]?.ignition);
  const d = km([states[t]!.lng, states[t]!.lat], [states[t + 6]!.lng, states[t + 6]!.lat]);
  assert.ok(d > (c!.speedKmh / 60) * 0.5 && d < (c!.speedKmh / 60) * 1.1, `moved ${d} km at ${c!.speedKmh} km/h`);
  assert.ok(states.every((s) => s.heading >= 0 && s.heading < 360));
});

test('demo alerts have their cars: one speeding, one low battery, one unplugged, one always parked', () => {
  const f = simFleet(['a', 'b', 'c', 'd', 'e'], 140);
  assert.ok(f[1]!.speedKmh >= 148);
  assert.ok(f[2]!.battery < 20);
  assert.equal(f[4]!.power, false);
  assert.equal(simAt(f[3]!, T0).speed, 0);
  assert.equal(simTrip(f[3]!, T0), null);
});

test('points for the ingest: one per car per step, in the generic JSON', () => {
  const cars = simFleet(['x', 'y']);
  const pts = simPoints(cars, T0, T0 + 60_000, 10);
  assert.equal(pts.length, 2 * 7);
  assert.deepEqual(Object.keys(pts[0]!).sort(), ['at', 'battery', 'device', 'fuel', 'heading', 'ignition', 'lat', 'lng', 'odometer', 'power', 'speed']);
  assert.equal(pts[0]!.device, 'SIM-0001');
  assert.ok(ROUTES.length >= 8);
});
