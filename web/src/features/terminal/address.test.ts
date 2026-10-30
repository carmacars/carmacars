import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseCaAddress } from './address.ts';

test('a mailing address in the usual shape', () => {
  assert.deepEqual(parseCaAddress('123 Example St, Unit 4, Toronto, ON M5V 1A1'),
    { line1: '123 Example St', line2: 'Unit 4', city: 'Toronto', state: 'ON', postal_code: 'M5V 1A1', country: 'CA' });
});
test('the city with the province, no space in the postal code, Canada at the end', () => {
  assert.deepEqual(parseCaAddress('9 Sample Rd, Mississauga ON l5b3c2, Canada'),
    { line1: '9 Sample Rd', line2: null, city: 'Mississauga', state: 'ON', postal_code: 'L5B 3C2', country: 'CA' });
});
test('not an address Terminal can use', () => {
  assert.equal(parseCaAddress('Toronto'), null);
  assert.equal(parseCaAddress('1 Main St, Toronto, XX M5V 1A1'), null);
  assert.equal(parseCaAddress(null), null);
});
