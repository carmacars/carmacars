// The rate form's number handling and words (src/features/rates/rates.ts).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RATE_FIELDS, centsInput, ratePayload, ratesEmpty, toCents, toKm } from './rates.ts';

test('dollars as typed become whole cents; text is passed on for the database to refuse on its field', () => {
  assert.equal(toCents('89'), 8900);
  assert.equal(toCents('$1,250.50'), 125050);
  assert.equal(toCents(' 0.35 '), 35);
  assert.equal(toCents(''), undefined);
  assert.equal(toCents(undefined), undefined);
  assert.equal(toCents('eighty'), 'eighty');
  assert.equal(toCents('89.555'), '89.555');
  assert.equal(toCents('0'), 0);
});

test('kilometres are whole numbers', () => {
  assert.equal(toKm('200'), 200);
  assert.equal(toKm('1,000'), 1000);
  assert.equal(toKm('20.5'), '20.5');
  assert.equal(toKm(''), undefined);
});

test('cents show as the input shows them', () => {
  assert.equal(centsInput(8900), '89');
  assert.equal(centsInput(8950), '89.50');
  assert.equal(centsInput(null), '');
});

test('one payload: rates and kilometres together; the defaults send no kilometres', () => {
  assert.deepEqual(ratePayload({ daily: '89', weekend: '99', weekly: '', monthly: '1800', km_mode: 'default', km_per_day: '300', deposit: '500' }),
    { daily: 8900, weekend: 9900, weekly: undefined, monthly: 180000, km_mode: 'default', deposit: 50000 });
  assert.deepEqual(ratePayload({ daily: '89', km_mode: 'custom', km_per_day: '300', overage: '0.45' }),
    { daily: 8900, weekend: undefined, weekly: undefined, monthly: undefined, km_mode: 'custom', deposit: undefined, km_per_day: 300, overage: 45 });
  assert.equal(ratesEmpty({ deposit: '500' }), true);
  assert.equal(ratesEmpty({ weekend: '99' }), false);
});

test('every rate says its unit, and the weekend rate says it is per day on Friday and Saturday', () => {
  const by = Object.fromEntries(RATE_FIELDS.map((f) => [f.key, f]));
  assert.match(by.daily!.label, /per day, Sunday to Thursday/);
  assert.match(by.weekend!.label, /per day, Friday and Saturday/);
  assert.match(by.weekend!.hint, /not for the whole weekend/);
  assert.match(by.weekly!.label, /price for 7 days/);
  assert.match(by.monthly!.label, /price for 30 days/);
  for (const f of RATE_FIELDS) assert.doesNotMatch(f.label + f.hint, /[—–]/);
});
