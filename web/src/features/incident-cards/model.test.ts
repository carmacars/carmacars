import { test } from 'node:test';
import assert from 'node:assert/strict';
import { carTitle, reportPath, slipKind, steps, type CardData } from './model.ts';

const base: CardData = { company: { trade_name: 'CarmaCars', support_phone: '647-555-0100', roadside_phone: '1-800-555-0100', incident_line: null }, policy: null, cars: [] };

test('the steps: safety first, 911, photos, exchange without admitting fault, support number, roadside, the app', () => {
  const s = steps(base);
  assert.match(s[0]!, /^Safety first/);
  assert.match(s[1]!, /911/);
  assert.ok(s.some((x) => /photos of all the cars/i.test(x)) && s.some((x) => /Do not admit fault/.test(x)));
  assert.ok(s.includes('Call or text CarmaCars support: 647-555-0100.'));
  assert.ok(s.includes('Roadside help for a breakdown: 1-800-555-0100.'));
  assert.match(s.at(-1)!, /Report it in the app with the QR code/);
});

test('no roadside line is printed when there is none or when it is the support number', () => {
  assert.ok(!steps({ ...base, company: { ...base.company, roadside_phone: null } }).some((x) => /Roadside/.test(x)));
  assert.ok(!steps({ ...base, company: { ...base.company, roadside_phone: '647-555-0100' } }).some((x) => /Roadside/.test(x)));
  assert.ok(steps({ ...base, company: { ...base.company, support_phone: null } }).includes('Call or text CarmaCars support.'));
});

test('the QR code opens the renter bookings, where the booking in progress has Report a problem', () => assert.equal(reportPath, '/account/bookings'));

test('the car line and the slip kind', () => {
  assert.equal(carTitle({ vehicle_id: 'x', year: 2024, make: 'Kia', model: 'K5', plate: 'AB1', vin: null }), '2024 Kia K5');
  assert.equal(slipKind('image/jpeg'), 'image'); assert.equal(slipKind('application/pdf'), 'pdf'); assert.equal(slipKind(null), null); assert.equal(slipKind('text/plain'), null);
});

test('nothing on a card names an amount', () => {
  const text = steps(base).join(' ');
  assert.doesNotMatch(text, /\$|premium|deductible/i);
});
