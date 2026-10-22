import assert from 'node:assert/strict';
import { test } from 'node:test';
import { billingWords, chipText, dueWords, filterCars, hstOf, kmText, preselect, rank, type CarRow } from './model.ts';

const car = (over: Partial<CarRow>): CarRow => ({
  vehicle_id: over.name ?? 'x', name: 'Car', plate: null, fleet_number: null, vehicle_status: 'available', class: 'standard', supply_type: 'program_owner', owner_name: null,
  current_km: 1000, km_per_day: 50, worst: 'ok', rank: 3, overdue: 0, due_soon: 0, unknown: 0, due_on: null, next: null, tires: null, chips: [], last_service_on: null, ...over
});

test('the most urgent car first, then the earliest due date, then the name', () => {
  const cars = [car({ name: 'B ok', worst: 'ok', rank: 3, due_on: '2026-12-01' }), car({ name: 'A unknown', worst: 'unknown', rank: 2, unknown: 3 }),
    car({ name: 'C overdue late', worst: 'overdue', rank: 0, overdue: 1, due_on: '2026-10-30' }), car({ name: 'D overdue early', worst: 'overdue', rank: 0, overdue: 2, due_on: '2026-10-01' }),
    car({ name: 'E soon', worst: 'due_soon', rank: 1, due_soon: 1, due_on: '2026-11-01' })];
  assert.deepEqual(filterCars(cars, {}).map((c) => c.name), ['D overdue early', 'C overdue late', 'E soon', 'A unknown', 'B ok']);
  assert.deepEqual(filterCars(cars, { sort: 'name' }).map((c) => c.name)[0], 'A unknown');
});

test('filters: due, overdue, due soon, unknown, ok; one item; search on plate and owner', () => {
  const cars = [car({ name: 'Malibu', plate: 'CDXR123', overdue: 1, worst: 'overdue', rank: 0, chips: [{ code: 'oil_filter', label: 'Oil and filter', status: 'overdue' }] }),
    car({ name: 'Jetta', owner_name: 'Olga Smith', due_soon: 1, worst: 'due_soon', rank: 1, chips: [{ code: 'oil_filter', label: 'Oil and filter', status: 'ok' }, { code: 'wipers', label: 'Wiper blades', status: 'due_soon' }] }),
    car({ name: 'Forte', unknown: 4, worst: 'unknown', rank: 2 }), car({ name: 'Civic' })];
  assert.deepEqual(filterCars(cars, { show: 'due' }).map((c) => c.name), ['Malibu', 'Jetta']);
  assert.deepEqual(filterCars(cars, { show: 'overdue' }).map((c) => c.name), ['Malibu']);
  assert.deepEqual(filterCars(cars, { show: 'due_soon' }).map((c) => c.name), ['Jetta']);
  assert.deepEqual(filterCars(cars, { show: 'unknown' }).map((c) => c.name), ['Forte']);
  assert.deepEqual(filterCars(cars, { show: 'ok' }).map((c) => c.name), ['Civic']);
  assert.deepEqual(filterCars(cars, { item: 'oil_filter', show: 'due' }).map((c) => c.name), ['Malibu']);
  assert.deepEqual(filterCars(cars, { item: 'wipers' }).map((c) => c.name), ['Jetta']);
  assert.deepEqual(filterCars(cars, { q: 'cdxr' }).map((c) => c.name), ['Malibu']);
  assert.deepEqual(filterCars(cars, { q: 'olga' }).map((c) => c.name), ['Jetta']);
});

test('words: km, chips, due, ranks', () => {
  assert.equal(kmText(21700), '21,700 km');
  assert.equal(kmText(null), '');
  assert.equal(chipText({ label: 'Oil and filter', status: 'overdue' }), 'Oil and filter: overdue');
  assert.equal(chipText({ label: 'Oil and filter', status: 'ok' }), 'Oil and filter');
  assert.equal(dueWords('2026-10-31', '2026-10-21'), 'in 10 days');
  assert.equal(dueWords('2026-10-20', '2026-10-21'), 'yesterday');
  assert.equal(dueWords('2026-10-21', '2026-10-21'), 'today');
  assert.ok(rank('overdue') < rank('due_soon') && rank('due_soon') < rank('unknown') && rank('unknown') < rank('ok'));
});

test('HST at the Program settings rate, rounded to the cent', () => {
  assert.equal(hstOf(8000), 1040);
  assert.equal(hstOf(12345), 1605);
  assert.equal(hstOf(10000, 500), 500);
});

test('the pop-up opens with the items due, or the ones a prompt names', () => {
  const items = [{ code: 'oil_filter', status: 'overdue' as const }, { code: 'wipers', status: 'due_soon' as const }, { code: 'battery', status: 'ok' as const }];
  assert.deepEqual(preselect(items), ['oil_filter', 'wipers']);
  assert.deepEqual(preselect(items, ['battery']), ['battery']);
});

test('the bill in words: who pays, billed or later, the assistant\'s limit, partner cars', () => {
  assert.match(billingWords('owner', true, 10000, null, 'program_owner'), /owner's next statement/);
  assert.match(billingWords('company', true, 10000, null, 'company'), /company expense/);
  assert.match(billingWords('claim', true, 10000, null, 'program_owner'), /claim/);
  assert.match(billingWords('renter', true, 10000, null, 'program_owner'), /renter at cost/);
  assert.match(billingWords('company', false, 10000, null, 'company'), /billed later/);
  assert.match(billingWords('company', true, 30000, 20000, 'company'), /an Admin bills it/);
  assert.match(billingWords('owner', true, 10000, null, 'partner'), /partner pays the shop directly/);
  assert.match(billingWords('none', true, 10000, null, 'company'), /No bill/);
  assert.match(billingWords('company', true, 0, null, 'company'), /No bill/);
});
