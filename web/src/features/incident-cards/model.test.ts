import { test } from 'node:test';
import assert from 'node:assert/strict';
import { COVERAGE_OPTIONS, CARDS_PER_SHEET, carTitle, coverageLead, reportPath, slipKind, steps, type CardData } from './model.ts';

const base: CardData = { company: { trade_name: 'CarmaCars', support_phone: '647-555-0100', roadside_phone: '1-800-555-0100', incident_line: null }, policy: null, cars: [] };

test('the steps: safety first, 911, photos, exchange without admitting fault, support number, roadside, the app', () => {
  const s = steps(base);
  assert.match(s[0]!, /^Safety first/);
  assert.match(s[1]!, /911/);
  assert.ok(s.some((x) => /photos of all the cars/i.test(x)) && s.some((x) => /Do not admit fault/.test(x)));
  assert.ok(s.includes('Call or text CarmaCars support: 647-555-0100.'));
  assert.ok(s.includes('Roadside help for a breakdown: 1-800-555-0100.'));
  assert.match(s.at(-1)!, /Report it in the app with the QR code: it opens your digital incident card/);
});

test('no roadside line is printed when there is none or when it is the support number', () => {
  assert.ok(!steps({ ...base, company: { ...base.company, roadside_phone: null } }).some((x) => /Roadside/.test(x)));
  assert.ok(!steps({ ...base, company: { ...base.company, roadside_phone: '647-555-0100' } }).some((x) => /Roadside/.test(x)));
  assert.ok(steps({ ...base, company: { ...base.company, support_phone: null } }).includes('Call or text CarmaCars support.'));
});

test('1150: the one QR code opens /incident (sign in, then the digital card of the booking in progress)', () => assert.equal(reportPath, '/incident'));

test('1150: the three renter coverage options, in order, each with what to show; option 4 is not on the card', () => {
  assert.deepEqual(COVERAGE_OPTIONS.map((o) => o.option), [1, 2, 3]);
  assert.match(COVERAGE_OPTIONS[0]!.title, /own auto insurance \(OPCF 27\)/);
  assert.match(COVERAGE_OPTIONS[1]!.title, /credit card rental coverage/);
  assert.match(COVERAGE_OPTIONS[2]!.title, /Protection Plan/);
  for (const o of COVERAGE_OPTIONS) assert.match(o.show, /^Show the insurance slip on this card/);
  assert.match(COVERAGE_OPTIONS[0]!.show, /your own insurance pink slip/);
  assert.ok(!COVERAGE_OPTIONS.some((o) => /included with the car/i.test(o.title)));
  assert.match(coverageLead, /QR code/);
});

test('1150: the card is generic: two to a Letter sheet, and its words name no car, plate, VIN, renter or booking', () => {
  assert.equal(CARDS_PER_SHEET, 2);
  const text = [...steps(base), ...COVERAGE_OPTIONS.flatMap((o) => [o.title, o.show]), coverageLead].join(' ');
  assert.doesNotMatch(text, /\bplate [A-Z0-9]|VIN [A-Z0-9]|booking [A-Z]{1,4}-/);
});

test('the car line and the slip kind', () => {
  assert.equal(carTitle({ year: 2024, make: 'Kia', model: 'K5' }), '2024 Kia K5');
  assert.equal(slipKind('image/jpeg'), 'image'); assert.equal(slipKind('application/pdf'), 'pdf'); assert.equal(slipKind(null), null); assert.equal(slipKind('text/plain'), null);
});

test('nothing on a card names an amount', () => {
  const text = [...steps(base), ...COVERAGE_OPTIONS.flatMap((o) => [o.title, o.show]), coverageLead].join(' ');
  assert.doesNotMatch(text, /\$|premium|deductible/i);
});
