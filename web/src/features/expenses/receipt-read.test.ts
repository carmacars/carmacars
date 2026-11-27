import { test } from 'node:test';
import assert from 'node:assert/strict';
import { guessCategory, mergeReads, normalizeReceipt } from './receipt-read.ts';

const CARS = [{ id: 'c1', name: '2021 Toyota RAV4', plate: 'CCAB123', vin: '2T3W1RFV5MW000001' }, { id: 'c2', name: '2019 Honda Civic', plate: 'TXYZ789', vin: null }];
const CATS = ['maint_oil', 'maint_tires', 'maint_tire_service', 'maint_service', 'field_fuel', 'field_cleaning', 'field_parking', 'field_parts', 'other'];
const ctx = { cars: CARS, categories: CATS, today: '2026-11-27' };

test('a receipt read: amount before tax, the tax, the date, the vendor, the category and the car by its plate', () => {
  const r = normalizeReceipt({ vendor: 'Quick Lube Ltd', date: '2026-11-23', subtotal: 85, tax: 11.05, total: 96.05, what: 'Synthetic oil change', plate: 'ccab 123', confidence: 92 }, ctx);
  assert.deepEqual([r.amount_cents, r.hst_cents, r.expense_on, r.vendor, r.category, r.vehicle_id, r.problems], [8500, 1105, '2026-11-23', 'Quick Lube Ltd', 'maint_oil', 'c1', []]);
  assert.equal(r.confidence, 92);
});

test('what is missing is worked out from the rest, and said', () => {
  const a = normalizeReceipt({ total: '$56.50', tax: '6.50', date: 'Nov 20, 2026', vendor: 'Esso' }, ctx);
  assert.deepEqual([a.amount_cents, a.hst_cents, a.expense_on, a.category], [5000, 650, '2026-11-20', 'field_fuel']);
  const b = normalizeReceipt({ total: 20, vendor: 'Spotless Car Wash' }, ctx);
  assert.deepEqual([b.amount_cents, b.hst_cents, b.expense_on, b.category], [2000, null, '2026-11-27', 'field_cleaning']);
  assert.match(b.problems.join(' | '), /No tax was read.*No date was read/);
  assert.ok(b.confidence < 50);
});

test('nothing made up: a date ahead, amounts that do not add up, a tax above the amount, no car', () => {
  const r = normalizeReceipt({ total: 100, subtotal: 80, tax: 13, date: '2027-01-05', vin: '2T3W1RFV5MW000009' }, ctx);
  assert.equal(r.expense_on, '2026-11-27');
  assert.match(r.problems.join(' | '), /ahead of today/);
  assert.match(r.problems.join(' | '), /add up to 93\.00, the total says 100\.00/);
  assert.equal(r.vehicle_id, null);
  assert.equal(normalizeReceipt({ subtotal: 10, tax: 50 }, ctx).hst_cents, null);
  assert.equal(normalizeReceipt(null, ctx).amount_cents, null);
});

test('the car by its VIN on a repair invoice; the category from the words, only an allowed one', () => {
  assert.equal(normalizeReceipt({ total: 450, tax: 51.77, what: 'Front brake pads and rotors', vin: '2T3W1RFV5MW000001' }, ctx).vehicle_id, 'c1');
  assert.equal(guessCategory('Front brake pads', [...CATS, 'maint_brakes']), 'maint_brakes');
  assert.equal(guessCategory('Brake repair labour', CATS), 'maint_service', 'a category not offered falls to the next that fits');
  assert.equal(guessCategory('Winter tires install and balance', CATS), 'maint_tire_service');
  assert.equal(guessCategory('Green P parking', CATS), 'field_parking');
  assert.equal(guessCategory('Office chair', CATS), null);
});

test('several photos of one expense: the amounts from the clearest read, the other fields from any', () => {
  const a = normalizeReceipt({ vendor: 'Tire Town', what: 'tires', confidence: 40 }, ctx);
  const b = normalizeReceipt({ total: 904, tax: 104, date: '2026-11-21', plate: 'TXYZ789', confidence: 88 }, ctx);
  const m = mergeReads([a, b])!;
  assert.deepEqual([m.amount_cents, m.hst_cents, m.vendor, m.category, m.vehicle_id, m.expense_on], [80000, 10400, 'Tire Town', 'maint_tires', 'c2', '2026-11-21']);
  assert.equal(mergeReads([]), null);
});
