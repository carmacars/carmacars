import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readValue, valuePrompt } from './estimate.ts';

test('the prompt names the car without any person', () => {
  assert.equal(valuePrompt({ year: 2024, make: 'Kia', model: 'K5', trim: 'GT', odometer_km: 21000, fuel: 'gasoline', body_type: 'sedan' }),
    'The car: 2024 Kia K5 GT (sedan), gasoline, 21,000 km. Estimate its current market value.');
});

test('the value kept: the high end of a sensible range, nothing for nonsense', () => {
  assert.deepEqual(readValue({ value_cad: 38000, low_cad: 34000, high_cad: 42000, basis: 'listings' }), { cents: 4200000, basis: 'listings' });
  assert.deepEqual(readValue({ value_cad: '38000', high_cad: 200000 }), { cents: 3800000, basis: '' });
  assert.equal(readValue({ value_cad: 50 }), null);
  assert.equal(readValue({ value_cad: 30000, low_cad: 40000 }), null);
  assert.equal(readValue(null), null);
});
