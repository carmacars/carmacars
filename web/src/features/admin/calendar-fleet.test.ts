import { test } from 'node:test';
import assert from 'node:assert/strict';
import { VIRTUAL_FROM, chipWords, filterCount, groupCars, jobLabel, jobRows, jobsOf, options, passes, rowsOf, topsOf, windowOf, NO_FILTER, type FleetCar, type TripEntry } from './calendar-fleet.ts';
import type { Avail } from './calendar-label.ts';

// r48 ops (docs/changes/2026-11-20-r48-ops-screens.md): the fleet calendar with 100+ cars, and the two end-of-trip jobs.
const car = (n: number, o: Partial<FleetCar> = {}): FleetCar => ({ id: `v${n}`, label: `2023 Car ${n}`, plate: `P${n}`, fleet_number: `F${n}`, status: 'available', class: n % 2 ? 'premium' : 'economy', owner: `Owner ${n % 3}`, ...o });
const av = (o: Partial<Avail> = {}): Avail => ({ kind: 'free', now: 'Available now', window: '', freeToday: true, freeAll: true, freeDays: 14, days: 14, ...o });

test('filters: status, class, owner and availability, each alone and together', () => {
  const c = car(1, { status: 'out_of_service' });
  assert.equal(passes(c, av(), NO_FILTER), true);
  assert.equal(passes(c, av(), { ...NO_FILTER, status: 'available' }), false);
  assert.equal(passes(c, av(), { ...NO_FILTER, status: 'out_of_service', cls: 'premium', owner: 'Owner 1' }), true);
  assert.equal(passes(c, av(), { ...NO_FILTER, owner: 'Owner 2' }), false);
  assert.equal(passes(c, av({ kind: 'out', freeToday: false, freeAll: false }), { ...NO_FILTER, avail: 'free_now' }), false);
  assert.equal(passes(c, av({ kind: 'out', freeToday: true, freeAll: false }), { ...NO_FILTER, avail: 'free_today' }), true);
  assert.equal(passes(c, av({ freeAll: false }), { ...NO_FILTER, avail: 'free_all' }), false);
  assert.equal(passes(c, av({ kind: 'off' }), { ...NO_FILTER, avail: 'off' }), true);
  assert.equal(passes(c, undefined, { ...NO_FILTER, avail: 'free_now' }), false);
  assert.equal(filterCount({ status: 'x', cls: '', owner: 'y', avail: 'out' }), 3);
});

test('filter choices come from the cars shown, with a count; a role given no owners gets no owner choice', () => {
  const cars = Array.from({ length: 6 }, (_, i) => car(i));
  assert.deepEqual(options(cars, 'class'), [['economy', 'Economy', 3], ['premium', 'Premium', 3]]);
  assert.deepEqual(options(cars, 'owner').map((o) => o[2]), [2, 2, 2]);
  assert.deepEqual(options([car(1, { status: 'out_of_service' })], 'status'), [['out_of_service', 'In shop', 1]]);
  assert.deepEqual(options(cars.map((c) => ({ ...c, owner: null })), 'owner'), []);
});

test('groups: by class, owner, status or availability; cars keep their order; a folded group shows only its heading', () => {
  const cars = Array.from({ length: 6 }, (_, i) => car(i));
  const free = (id: string) => av({ freeToday: id !== 'v0', kind: id === 'v0' ? 'out' : 'free' });
  assert.deepEqual(groupCars(cars, 'none', free).map((g) => [g.key, g.cars.length, g.free]), [['', 6, 5]]);
  const byClass = groupCars(cars, 'class', free);
  assert.deepEqual(byClass.map((g) => [g.label, g.cars.map((c) => c.id), g.free]), [['Economy', ['v0', 'v2', 'v4'], 2], ['Premium', ['v1', 'v3', 'v5'], 3]]);
  assert.deepEqual(groupCars(cars, 'avail', free).map((g) => g.label), ['Available now', 'Out or booked now']);
  assert.deepEqual(groupCars([car(1, { class: null }), car(2)], 'class', free).map((g) => g.label), ['Economy', 'No class']);
  const rows = rowsOf(byClass, new Set(['economy']));
  assert.deepEqual(rows.map((r) => r.kind === 'group' ? `${r.label}:${r.open}` : r.car.id), ['Economy:false', 'Premium:true', 'v1', 'v3', 'v5']);
  assert.deepEqual(rowsOf(groupCars(cars, 'none', free), new Set()).length, 6);
});

test('a long list draws only the rows near the screen; the rest is space of the same height', () => {
  assert.ok(VIRTUAL_FROM >= 30);
  const tops = topsOf(Array.from({ length: 200 }, () => 62));
  assert.equal(tops[200], 12_400);
  const top = windowOf(tops, 0, 600);
  assert.deepEqual([top.start, top.before], [0, 0]);
  assert.ok(top.end < 30 && top.end >= 10, `${top.end} rows at the top`);
  assert.equal(top.before + (top.end - top.start) * 62 + top.after, 12_400);
  const mid = windowOf(tops, 6200, 600);
  assert.ok(mid.start > 80 && mid.end < 125 && mid.end - mid.start < 40);
  assert.equal(mid.before, tops[mid.start]);
  assert.equal(mid.before + (mid.end - mid.start) * 62 + mid.after, 12_400);
  const end = windowOf(tops, 99_999, 600);
  assert.equal(end.end, 200); assert.equal(end.after, 0);
  assert.deepEqual(windowOf(topsOf([]), 0, 600), { start: 0, end: 0, before: 0, after: 0 });
  // rows of different heights (stacked bars, a group heading)
  const mixed = topsOf([40, 62, 114, 62, 40, 88]);
  assert.deepEqual(mixed, [0, 40, 102, 216, 278, 318, 406]);
  assert.deepEqual(windowOf(mixed, 110, 50, 0), { start: 2, end: 3, before: 102, after: 190 });
});

const E = (o: Partial<TripEntry>): TripEntry => ({ type: 'booking', id: 'b1', detail: null, starts_at: '2026-11-20T15:00:00Z', ends_at: '2026-11-23T20:30:00Z', status: 'confirmed', reason: null, note: null, booking_number: 'CC-1', ...o });

test('the end of a trip is two jobs: the return check-out with its time, and the post-trip cleaning', () => {
  const jobs = jobsOf([E({})]);
  assert.deepEqual(jobs.map((j) => [jobLabel(j).name, j.starts_at, jobLabel(j).done]), [['Return check-out', '2026-11-23T20:30:00Z', false], ['Post-trip cleaning', '2026-11-23T20:30:00Z', false]]);
  assert.equal(chipWords(jobLabel(jobs[0]!)), 'Check-out 3:30 pm');
  assert.equal(jobLabel(jobs[0]!).full, 'Return check-out: due 3:30 pm');
  // a return is never called a check-in
  assert.ok(jobs.every((j) => !/check-in/i.test(jobLabel(j).full)));
});

test('a return that happened shows when the car actually came back, not when it was due', () => {
  const back = E({ status: 'returned', returned_at: '2026-11-23T22:05:00Z', cleaned_at: '2026-11-23T23:10:00Z' });
  const [out, clean] = jobsOf([back]);
  assert.equal(jobLabel(out!).full, 'Return check-out: returned 5:05 pm');
  assert.equal(out!.starts_at, '2026-11-23T22:05:00Z');
  assert.deepEqual([jobLabel(clean!).done, jobLabel(clean!).time], [true, '6:10 pm']);
});

test('a field job and the cleaning block of a trip are used as they are, never doubled; other jobs keep their name', () => {
  const entries = [E({ status: 'returned', returned_at: '2026-11-23T21:00:00Z' }),
    E({ type: 'field_job', id: 'j1', detail: 'return_check_in', booking_number: null, for_booking: 'CC-1', starts_at: '2026-11-23T20:30:00Z', ends_at: '2026-11-23T21:30:00Z', status: 'scheduled', assignee: 'Fay Field' }),
    E({ type: 'block', id: 'k1', reason: 'cleaning', note: 'Cleaning after booking CC-1', booking_number: null, for_booking: 'CC-1', job: 'post_trip_cleaning', starts_at: '2026-11-23T21:00:00Z', ends_at: '2026-11-23T23:00:00Z', status: 'blocked' }),
    E({ type: 'field_job', id: 'j2', detail: 'photo_shoot', booking_number: null, starts_at: '2026-11-22T15:00:00Z', ends_at: null, status: 'scheduled' }),
    E({ type: 'block', id: 'k2', reason: 'service', note: 'Brakes', booking_number: null, starts_at: '2026-11-24T15:00:00Z' })];
  const jobs = jobsOf(entries);
  assert.deepEqual(jobs.map((j) => `${j.type}:${jobLabel(j).name}`), ['field_job:Photo shoot', 'field_job:Return check-out', 'block:Post-trip cleaning']);
  const out = jobs[1]!;
  // the booking came back, so the job reads done at that time even while the field job is still open
  assert.deepEqual([jobLabel(out).done, jobLabel(out).time, out.assignee], [true, '4:00 pm', 'Fay Field']);
  assert.equal(jobLabel(jobs[2]!).time, '4:00 pm to 6:00 pm');
});

test('a placeholder, a request and an offer have no end-of-trip jobs', () => {
  assert.deepEqual(jobsOf([E({ placeholder: true }), E({ id: 'b2', booking_number: 'CC-2', status: 'requested' }), E({ id: 'b3', booking_number: 'CC-3', status: 'offered' })]), []);
});

test('job chips at the same time go one above the other, never on top of each other, and stay inside the days shown', () => {
  const jobs = jobsOf([E({}), E({ id: 'b2', booking_number: 'CC-2', starts_at: '2026-11-23T21:00:00Z', ends_at: '2026-11-26T20:00:00Z' })]);
  const px = (iso: string) => (Date.parse(iso) - Date.parse('2026-11-20T05:00:00Z')) / 86_400_000 * 80;
  const { at, rows } = jobRows(jobs, px, 14 * 80);
  assert.equal(rows, 2);
  const boxes = [...at.values()];
  for (const a of boxes) for (const b of boxes) if (a !== b && a.row === b.row) assert.ok(a.left + a.width <= b.left || b.left + b.width <= a.left, 'no chip over another');
  // a job at the very end of the days shown is pulled back inside
  const edge = jobRows(jobsOf([E({ ends_at: '2026-12-04T04:30:00Z' })]), px, 14 * 80);
  for (const b of edge.at.values()) assert.ok(b.left + b.width <= 14 * 80);
});
