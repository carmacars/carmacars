// The odometer and fuel reading (release 35, 0910): the model's answer checked, the eighths, the question, the live selfie,
// what is still missing, and what the server refuses.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FUEL_EIGHTHS, confirmQuestion, dashFromModel, eighthsToPct, emptyReading, fuelWords, pctToEighths, readingPayload, readingPhotos, readingProblem,
  readingValues, selfieLive, serverReadingProblem, pickDash } from './reading.ts';

test('the fuel in eighths: nine levels, stored as whole percentages that round back', () => {
  assert.equal(FUEL_EIGHTHS.length, 9);
  for (let e = 0; e <= 8; e++) assert.equal(pctToEighths(eighthsToPct(e)), e);
  assert.equal(fuelWords(6), '3/4');
  assert.equal(fuelWords(8), 'Full');
});

test('the question after the photo is read', () => {
  assert.equal(confirmQuestion(45210, 6), 'Odometer 45,210 km, fuel 3/4: correct?');
});

test('the model answer is checked: km, miles converted, fractions, percent, unreadable', () => {
  assert.deepEqual(dashFromModel({ odometer: 45210, unit: 'km', fuel_eighths: 6 }), { odometer_km: 45210, fuel_eighths: 6 });
  assert.deepEqual(dashFromModel({ odometer: '12,000 mi', unit: 'mi', fuel: '1/2' }), { odometer_km: 19312, fuel_eighths: 4 });
  assert.deepEqual(dashFromModel({ odometer: 30000, fuel_percent: '80%' }), { odometer_km: 30000, fuel_eighths: 6 });
  assert.deepEqual(dashFromModel({ odometer: 30000, fuel: 'Full' }), { odometer_km: 30000, fuel_eighths: 8 });
  assert.deepEqual(dashFromModel({ odometer: 99999999, fuel_eighths: 12 }), { odometer_km: null, fuel_eighths: null });
  assert.deepEqual(dashFromModel({ odometer: 1000, fuel_eighths: 4, readable: false }), { odometer_km: null, fuel_eighths: null });
  assert.deepEqual(dashFromModel(null), { odometer_km: null, fuel_eighths: null });
});

test('a selfie is live when the camera took it in the last 10 minutes', () => {
  const now = Date.parse('2026-11-08T12:00:00Z');
  assert.equal(selfieLive(now - 60_000, now), true);
  assert.equal(selfieLive(now - 3 * 86_400_000, now), false);
  assert.equal(selfieLive(null, now), false);
});

test('confirmed values are sent as read; otherwise what was typed; each missing piece is named', () => {
  const s = emptyReading();
  assert.match(readingProblem(s)!, /dashboard/);
  s.dash = { bucket: 'condition-photos', path: 'a.jpg' };
  s.ai = { odometer_km: 45210, fuel_eighths: 6, model: '@cf/x' };
  assert.match(readingProblem(s)!, /odometer/);
  s.confirmed = true;
  assert.deepEqual(readingValues(s), { odometer_km: '45210', fuel_pct: '75', source: 'read_confirmed' });
  assert.match(readingProblem(s)!, /selfie/);
  s.selfie = { bucket: 'condition-photos', path: 'b.jpg', taken_at: '2026-11-08T12:00:00Z', live: true, latitude: null, longitude: null };
  assert.equal(readingProblem(s), null);
  assert.deepEqual(readingPhotos(s).map((p) => p.angle), ['dashboard', 'selfie']);
  assert.equal(readingPayload(s).source, 'read_confirmed');
  s.confirmed = false; s.km = '45,300'; s.fuel = '63';
  assert.deepEqual(readingValues(s), { odometer_km: '45300', fuel_pct: '63', source: 'typed' });
  s.fuel = '60';
  assert.match(readingProblem(s)!, /fuel/);
});

test('the server refuses a check-out or check-in without the dashboard photo, the readings or the selfie', () => {
  assert.match(serverReadingProblem({ odometer_km: '1', fuel_pct: '100', photos: [] })!, /dashboard/);
  assert.match(serverReadingProblem({ odometer_km: '', fuel_pct: '100', photos: [{ angle: 'dashboard' }] })!, /odometer/);
  assert.match(serverReadingProblem({ odometer_km: '10', fuel_pct: '70', photos: [{ angle: 'dashboard' }] })!, /fuel/);
  assert.match(serverReadingProblem({ odometer_km: '10', fuel_pct: '75', photos: [{ angle: 'dashboard' }] })!, /selfie/);
  assert.equal(serverReadingProblem({ odometer_km: '10', fuel_pct: '75', photos: [{ angle: 'dashboard' }, { angle: 'selfie' }] }), null);
});

test('the dashboard photo of a side: its own tag first, then odometer or fuel, then the cluster shot', () => {
  const ps = [{ angle: null, shot: 'instrument_cluster', id: 1 }, { angle: 'odometer', shot: 'instrument_cluster', id: 2 }, { angle: 'dashboard', shot: 'instrument_cluster', id: 3 }];
  assert.equal(pickDash(ps)?.id, 3);
  assert.equal(pickDash(ps.slice(0, 2))?.id, 2);
  assert.equal(pickDash(ps.slice(0, 1))?.id, 1);
  assert.equal(pickDash([{ angle: 'front', shot: 'front' }]), null);
});
