import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fromComponents, fromLabel, toLine } from './address-parts.ts';

test('Google components fill each part, the postal code with its space', () => {
  const p = fromComponents([
    { longText: '65', types: ['street_number'] }, { longText: 'Front Street West', shortText: 'Front St W', types: ['route'] },
    { longText: '4', types: ['subpremise'] }, { longText: 'Toronto', types: ['locality', 'political'] },
    { longText: 'Ontario', shortText: 'ON', types: ['administrative_area_level_1'] }, { longText: 'M5J1E6', types: ['postal_code'] },
    { longText: 'Canada', shortText: 'CA', types: ['country'] }]);
  assert.deepEqual(p, { street: '65 Front Street West', unit: '4', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' });
});

test('no components: nothing to fill from them', () => {
  assert.equal(fromComponents([]), null);
  assert.equal(fromComponents(undefined), null);
});

test('a one-line Canadian address is split', () => {
  assert.deepEqual(fromLabel('65 Front St W, Unit 4, Toronto, ON M5J 1E6, Canada'), { street: '65 Front St W', unit: '4', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' });
  assert.deepEqual(fromLabel('Union Station, 65 Front Street West, Toronto, ON'), { street: '65 Front Street West', unit: '', city: 'Toronto', province: 'ON', postal_code: '', country: 'Canada' });
});

test('a US address keeps its ZIP code and country', () => {
  const p = fromLabel('1 Main St, Buffalo, NY 14202, USA');
  assert.equal(p.city, 'Buffalo'); assert.equal(p.province, 'NY'); assert.equal(p.postal_code, '14202'); assert.equal(p.country, 'United States');
});

test('back to one line', () => {
  assert.equal(toLine({ street: '65 Front St W', unit: '4', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' }), '65 Front St W, Unit 4, Toronto, ON M5J 1E6');
});
