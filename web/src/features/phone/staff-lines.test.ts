import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lineBuyBlocked, linePrice, maskedNumber, pickNumber } from './staff-lines.ts';

// R51 (5200, REQ-132): the parts of buying a staff line that decide what is bought, shown and refused.
test('the first voice number Twilio offers, in E.164', () => {
  assert.equal(pickNumber({ available_phone_numbers: [{ phone_number: 'bad' }, { phone_number: '+16475550199' }] }), '+16475550199');
  assert.equal(pickNumber({ available_phone_numbers: [] }), null);
  assert.equal(pickNumber(null), null);
});

test('the monthly price of a local number from the Pricing API', () => {
  const j = { price_unit: 'usd', phone_number_prices: [{ number_type: 'toll free', base_price: '2.00', current_price: '2.00' }, { number_type: 'local', base_price: '1.15', current_price: '1.15' }] };
  assert.deepEqual(linePrice(j), { monthly: '1.15', currency: 'USD' });
  assert.equal(linePrice({ price_unit: 'USD', phone_number_prices: [{ number_type: 'mobile', current_price: '1' }] }), null, 'no local price: nothing to confirm');
  assert.equal(linePrice({ phone_number_prices: [{ number_type: 'local', current_price: '1.15' }] }), null, 'no currency: nothing to confirm');
});

test('an Admin sees the last 4 digits only', () => {
  assert.equal(maskedNumber('+16475550199'), '•••-•••-0199');
  assert.ok(!maskedNumber('+16475550199').includes('647'));
});

test('a number is never bought from a test server', () => {
  for (const b of ['http://localhost:3000', 'https://localhost', 'http://127.0.0.1:8787', 'https://carmacars.test', 'http://carmacars.ca', 'https://staging.carmacars.ca', 'https://carmacars.ca.evil.example', 'https://preview.pages.dev', 'not a url'])
    assert.ok(lineBuyBlocked(b), b);
  assert.equal(lineBuyBlocked('https://carmacars.ca'), null);
  assert.equal(lineBuyBlocked('https://www.carmacars.ca'), null);
});
