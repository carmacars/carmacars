import { test } from 'node:test';
import assert from 'node:assert/strict';
import { byBucket, dayWords, dueIn, issuesOf, missingAngles, nextLine, serviceWords, slotsByDay, torontoDay, type Visit } from './model.ts';

const visit = (over: Partial<Visit>): Visit => ({
  id: 'v1', booking_id: 'b1', vehicle_id: 'c1', due_on: '2026-12-14', status: 'due', bucket: 'due', place: null, slot_at: null, request_note: null,
  place_words: 'At the CarmaCars office', time_words: '', reminded_at: null, followup_at: null, done_at: null, odometer_km: null, damage_found: null,
  damage_note: null, tread_mm: null, fluids_ok: null, warning_lights: null, next_service: null, closed_reason: null, ...over
});

test('the renter card says around the due date, and the exact time once booked', () => {
  assert.equal(nextLine({ on: false }), null);
  assert.equal(nextLine({ on: true, next_on: '2026-12-14', visit: null }), 'Next check-in visit: around Monday, December 14');
  assert.equal(nextLine({ on: true, visit: visit({ due_on: '2026-12-10' }) }), 'Next check-in visit: around Thursday, December 10');
  assert.equal(nextLine({ on: true, visit: visit({ status: 'booked', slot_at: '2026-12-14T19:30:00Z' }) }), 'Your check-in visit: Monday, December 14, 2:30 pm');
  assert.equal(nextLine({ on: true, visit: visit({ status: 'booked', place: 'request' }) }), 'Your check-in visit: by request, we will confirm the time');
});

test('the five photos: four sides and the odometer', () => {
  assert.deepEqual(missingAngles([]), ['front', 'rear', 'left', 'right', 'odometer']);
  assert.deepEqual(missingAngles([{ angle: 'front' }, { angle: 'odometer' }, { angle: 'left' }]), ['rear', 'right']);
});

test('slots group by day in order; the queue groups by bucket', () => {
  const g = slotsByDay([{ at: '2026-12-15T15:00:00Z', day: '2026-12-15' }, { at: '2026-12-14T16:00:00Z', day: '2026-12-14' }, { at: '2026-12-14T15:00:00Z', day: '2026-12-14' }]);
  assert.deepEqual(g.map(([d, s]) => [d, s.length]), [['2026-12-14', 2], ['2026-12-15', 1]]);
  assert.equal(g[0]![1][0]!.at, '2026-12-14T15:00:00Z');
  const b = byBucket([visit({ bucket: 'overdue' }), visit({ id: 'v2', bucket: 'booked' }), visit({ id: 'v3', bucket: 'done' })]);
  assert.deepEqual([b.booked.length, b.due.length, b.overdue.length, b.done.length], [1, 0, 1, 1]);
});

test('what to look after matches the database rule', () => {
  assert.deepEqual(issuesOf({ tread_mm: 5, fluids_ok: true, warning_lights: 'none', next: { label: 'Oil and filter', status: 'ok', km_left: 3000, due_on: null } }), []);
  assert.deepEqual(issuesOf({ tread_mm: 2.5, fluids_ok: false, warning_lights: 'Check engine', next: { label: 'Oil and filter', status: 'due_soon', km_left: 400, due_on: null } }),
    ['Oil and filter due soon', 'tire tread 2.5 mm', 'fluids to top up or check', 'warning light: Check engine']);
});

test('words for days and services', () => {
  assert.equal(dayWords('2026-12-14'), 'Monday, December 14');
  assert.equal(dueIn('2026-12-14', '2026-12-14'), 'today');
  assert.equal(dueIn('2026-12-17', '2026-12-14'), 'in 3 days');
  assert.equal(dueIn('2026-12-12', '2026-12-14'), '2 days ago');
  assert.equal(torontoDay('2026-12-15T03:00:00Z'), '2026-12-14');
  assert.equal(serviceWords(null), 'No service schedule yet');
  assert.equal(serviceWords({ label: 'Oil and filter', status: 'ok', km_left: 1200, due_on: null }), 'Oil and filter in 1,200 km');
  assert.equal(serviceWords({ label: 'Oil and filter', status: 'overdue', km_left: -300, due_on: null }), 'Oil and filter: overdue by 300 km');
});
