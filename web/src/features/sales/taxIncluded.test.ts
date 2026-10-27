import { test } from 'node:test';
import assert from 'node:assert/strict';
import { beforeTax, bpsOf, breakdown, convertTyped, dollarsToCents, hstOf, linesBeforeTax, solveRental, splitIncluded, toBeforeTax, totalDifference, withTax } from './taxIncluded.ts';

const HST = 1300;   // the tests' setting; the screens read it from the quote or the booking

test('HST rounds half away from zero, as public.calc_bps', () => {
  assert.equal(hstOf(4425, HST), 575);            // 575.25
  assert.equal(hstOf(23894, HST), 3106);          // 3106.22
  assert.equal(bpsOf(50, 1000), 5);               // exactly .0
  assert.equal(bpsOf(5, 1000), 1);                // 0.5 rounds up
  assert.equal(bpsOf(-5, 1000), -1);              // -0.5 rounds away from zero (a discount line)
  assert.equal(hstOf(-2500, HST), -325);
});

test('before tax is round(after / (1 + rate)), as app.price_before_tax', () => {
  assert.equal(beforeTax(10000, HST), 8850);      // 88.4956
  assert.equal(beforeTax(11300, HST), 10000);
  assert.equal(beforeTax(21000, HST), 18584);
  assert.equal(beforeTax(9999, HST), 8849);
  assert.equal(beforeTax(123456, HST), 109253);
  assert.equal(beforeTax(5, HST), 4);
  assert.equal(beforeTax(1, HST), 1);
  assert.equal(beforeTax(0, HST), 0);
  assert.equal(beforeTax(10000, 0), 10000);       // no HST
  assert.equal(beforeTax(10500, 500), 10000);     // another rate from the settings
});

test('tax included splits to the cent: before + HST is exactly the amount typed, for every amount up to $1,000', () => {
  for (let c = 0; c <= 100000; c++) { const s = splitIncluded(c, HST); assert.equal(s.before + s.hst, c); }
  assert.deepEqual(splitIncluded(27000, HST), { before: 23894, hst: 3106, with: 27000 });
});

test('$320 cash with a $50 Protection Plan after tax: rental 238.94 + plan 44.25 + HST 36.81 = 320.00', () => {
  const plan = toBeforeTax(5000, 'after', true, HST);
  assert.equal(plan, 4425);
  assert.equal(withTax(plan, HST), 5000);
  const rentalWith = solveRental(32000, withTax(plan, HST), 0)!;   // no rental line yet: the total is the plan alone
  assert.equal(rentalWith, 27000);
  const r = splitIncluded(rentalWith, HST);
  assert.equal(r.before, 23894);
  const lines = [{ amount_cents: r.before, hst_cents: r.hst }, { amount_cents: plan, hst_cents: hstOf(plan, HST) }];
  assert.deepEqual(breakdown(lines), { subtotal: 28319, hst: 3681, total: 32000 });
});

test('the total typed back-solves the rental line, the other lines kept', () => {
  // the quote now: rental $200.00 + $26.00, delivery $50.00 + $6.50 = $282.50
  const total = 20000 + 2600 + 5000 + 650;
  const w = solveRental(30000, total, 20000 + 2600)!;
  assert.equal(w, 24350);
  const r = splitIncluded(w, HST);
  assert.equal(r.before + r.hst + 5000 + 650, 30000);
  assert.equal(solveRental(1000, total, 22600), null);   // below the other lines: no rental charge makes it
  // a line that follows the rental (10% non-refundable discount) moves with it: a second step lands it
  const priced = (with_: number) => { const s = splitIncluded(with_, HST); const d = -bpsOf(s.before, 1000); return with_ + d + hstOf(d, HST) + 5650; };
  let rw = 22600; let t = priced(rw);
  for (let i = 0; i < 6 && t !== 30000; i++) { rw = solveRental(30000, t, rw)!; t = priced(rw); }
  assert.equal(t, 30000);
});

test('lines without HST are unaffected; lines typed after tax report the cents rounding left', () => {
  assert.equal(toBeforeTax(5000, 'after', false, HST), 5000);
  assert.equal(toBeforeTax(5000, 'before', true, HST), 5000);
  const { cents, residual } = linesBeforeTax([{ key: 'coverage_sold', typed: 5000, hst: true }, { key: 'delivery', typed: 4000, hst: true }, { key: 'custom', typed: 2500, hst: false }], 'after', HST);
  assert.deepEqual(cents, { coverage_sold: 4425, delivery: 3540, custom: 2500 });
  // $40.00 after tax: 35.40 before, 4.60 HST (4.602): exactly 40.00, nothing left over
  assert.equal(residual, 0);
  // $1.00 after tax: 0.88 + 0.11 = 0.99, a cent short; $2.00: 1.77 + 0.23 = 2.00
  const odd = linesBeforeTax([{ key: 'a', typed: 100, hst: true }, { key: 'b', typed: 200, hst: true }], 'after', HST);
  assert.deepEqual(odd.cents, { a: 88, b: 177 });
  assert.equal(odd.residual, 1);
  assert.equal(linesBeforeTax([{ key: 'a', typed: 100, hst: true }], 'before', HST).residual, 0);
});

test('the toggle keeps a box meaning the same money', () => {
  assert.equal(convertTyped(4425, 'before', 'after', true, HST), 5000);
  assert.equal(convertTyped(5000, 'after', 'before', true, HST), 4425);
  assert.equal(convertTyped(5000, 'after', 'before', false, HST), 5000);
  for (let b = 0; b <= 20000; b++) assert.equal(convertTyped(convertTyped(b, 'before', 'after', true, HST), 'after', 'before', true, HST), b);
});

test('dollars typed and the difference in words', () => {
  assert.equal(dollarsToCents('$1,250.50'), 125050);
  assert.equal(dollarsToCents(' 320 '), 32000);
  assert.equal(dollarsToCents(''), null);
  assert.equal(dollarsToCents('abc'), null);
  const m = (c: number) => `$${(c / 100).toFixed(2)}`;
  assert.equal(totalDifference(32000, 32000, m), '');
  assert.equal(totalDifference(32001, 32000, m), 'The total priced is $320.01: $0.01 more than the $320.00 typed.');
  assert.equal(totalDifference(31999, 32000, m), 'The total priced is $319.99: $0.01 less than the $320.00 typed.');
  assert.equal(totalDifference(31999, null, m), '');
});
