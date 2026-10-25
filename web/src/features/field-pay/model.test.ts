// Field pay (0165) and vehicle class rules: the pure helpers.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { csvCell, decimalHours, dollarsText, elapsedClock, hoursText, methodWords, overtimeWords, payRunCsv, plainMoney, ruleProblems, ruleThen, ruleWhen, type PayCsvRow } from './model.ts';

test('hours are written in whole hours and minutes', () => {
  assert.equal(hoursText(510), '8 h 30 min');
  assert.equal(hoursText(480), '8 h');
  assert.equal(hoursText(45), '45 min');
  assert.equal(hoursText(0), '0 min');
  assert.equal(hoursText(-5), '0 min');
  assert.equal(hoursText(null), '0 min');
  assert.equal(hoursText('90'), '1 h 30 min');
});

test('money and decimal hours for a spreadsheet', () => {
  assert.equal(dollarsText(15300), '$153.00');
  assert.equal(dollarsText(-250), '-$2.50');
  assert.equal(plainMoney(15300), '153.00');
  assert.equal(plainMoney(undefined), '0.00');
  assert.equal(decimalHours(510), '8.50');
  assert.equal(decimalHours(20), '0.33');
});

test('a CSV cell is quoted when it needs to be and never starts a formula', () => {
  assert.equal(csvCell('plain'), 'plain');
  assert.equal(csvCell('a, b'), '"a, b"');
  assert.equal(csvCell('say "hi"'), '"say ""hi"""');
  assert.equal(csvCell('=SUM(A1)'), "'=SUM(A1)");
  assert.equal(csvCell('+1 416'), "'+1 416");
  assert.equal(csvCell('@x'), "'@x");
  assert.equal(csvCell('-5.00'), '-5.00');
  assert.equal(csvCell('-cmd'), "'-cmd");
  assert.equal(csvCell(null), '');
  assert.equal(csvCell(12), '12');
});

const row = (o: Partial<PayCsvRow>): PayCsvRow => ({ statement: 'PS-1001', name: 'Ann Field', minutes: 510, overtime_minutes: 0, rate_cents: 1800, wage_cents: 15300, overtime_cents: 0, vacation_cents: 0,
  commission_cents: 3600, gross_cents: 18900, status: 'paid', paid_on: '2026-11-06', method: 'e_transfer', reference: 'CA123', ...o });

test('the pay run CSV has a header, a row for each person and a total', () => {
  const csv = payRunCsv({ start: '2026-10-18', end: '2026-10-31' }, [row({}), row({ statement: 'PS-1002', name: 'Bob, Jr', minutes: 330, wage_cents: 11000, rate_cents: 2000, commission_cents: 0, gross_cents: 11000, status: 'pending', paid_on: null, method: null, reference: null })]);
  const lines = csv.trimEnd().split('\r\n');
  assert.equal(lines.length, 4);
  assert.match(lines[0]!, /^Statement,Staff member,Period start,Period end,Hours,/);
  assert.equal(lines[1], 'PS-1001,Ann Field,2026-10-18,2026-10-31,8.50,0.00,18.00,153.00,0.00,0.00,36.00,189.00,paid,2026-11-06,e_transfer,CA123');
  assert.match(lines[2]!, /^PS-1002,"Bob, Jr",/);
  assert.equal(lines[3], ',Total,2026-10-18,2026-10-31,14.00,0.00,,263.00,0.00,0.00,36.00,299.00,,,,');
  assert.ok(csv.endsWith('\r\n'));
});

test('the shift clock counts hours and minutes', () => {
  const t0 = Date.parse('2026-10-26T13:00:00Z');
  assert.equal(elapsedClock('2026-10-26T13:00:00Z', t0), '0:00');
  assert.equal(elapsedClock('2026-10-26T13:00:00Z', t0 + 125 * 60_000), '2:05');
  assert.equal(elapsedClock('2026-10-26T13:00:00Z', t0 - 60_000), '0:00');
});

test('payment methods and the overtime sentence', () => {
  assert.equal(methodWords('e_transfer'), 'e-Transfer');
  assert.equal(methodWords('cash'), 'Cash');
  assert.equal(methodWords('wise'), '');
  assert.equal(overtimeWords(false, 44, 15000), 'Overtime is off: every hour is paid at the hourly rate.');
  assert.match(overtimeWords(true, 44, 15000), /past 44 in a week .* 150%/);
});

test('a class rule is described in words', () => {
  assert.equal(ruleWhen({ make_key: 'porsche', model_re: '^911', trim_re: null, body_re: null }), 'make porsche, model ^911');
  assert.equal(ruleWhen({ make_key: null, model_re: null, trim_re: null, body_re: null }), 'any car');
  assert.equal(ruleThen({ class_label: 'Exotic', aged_years: null, aged_class_label: null }), 'Exotic');
  assert.equal(ruleThen({ class_label: 'Exotic', aged_years: 10, aged_class_label: 'Luxury' }), 'Exotic, Luxury once 10 years old');
});

test('a class rule is checked before it is sent', () => {
  const ok = { rank: 10, make: 'Porsche', class: 'exotic', note: 'Porsche sports cars' };
  assert.deepEqual(ruleProblems(ok), []);
  assert.match(ruleProblems({ ...ok, make: '' })[0]!, /at least one condition/);
  assert.ok(ruleProblems({ ...ok, rank: 0 }).some((p) => /rank/.test(p)));
  assert.ok(ruleProblems({ ...ok, rank: 1000 }).some((p) => /rank/.test(p)));
  assert.ok(ruleProblems({ ...ok, class: '' }).some((p) => /class/.test(p)));
  assert.ok(ruleProblems({ ...ok, note: ' ' }).some((p) => /note/.test(p)));
  assert.ok(ruleProblems({ ...ok, model_re: '^(abc' }).some((p) => /not a valid pattern/.test(p)));
  assert.deepEqual(ruleProblems({ ...ok, model_re: '^911', aged_years: 10, aged_class: 'luxury' }), []);
  assert.ok(ruleProblems({ ...ok, aged_years: 10 }).some((p) => /go together/.test(p)));
  assert.ok(ruleProblems({ ...ok, aged_class: 'luxury' }).some((p) => /go together/.test(p)));
  assert.ok(ruleProblems({ ...ok, aged_years: 99, aged_class: 'luxury' }).some((p) => /1 to 60/.test(p)));
  assert.ok(ruleProblems({ ...ok, aged_years: 5, aged_class: 'exotic' }).some((p) => /same as the class/.test(p)));
});
