import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addMonths, computeReturns, firstOfNextMonth, monthlyReturnCents, monthsBetween } from './returns.ts';

// Schedule B of the Investment Agreement (docs/source/v2_investment.md): $20,000 invested on January 1, 2027 at 30%,
// Lockup End Date July 1, 2027.
const B = { amountCents: 2_000_000, yearlyBps: 3000, investmentDate: '2027-01-01' };

test('Schedule B, example 1: paid monthly, nothing for January to June, $500 a month from July, first paid August 15, 2027', () => {
  const r = computeReturns({ ...B, years: 1, reinvestMonths: 0 });
  assert.equal(r.lockupEndDate, '2027-07-01');
  assert.equal(r.months[0].month, '2027-07-01');
  assert.equal(r.months.length, 6);
  assert.ok(r.months.every((m) => m.returnCents === 50000 && m.mode === 'pay'));
  assert.equal(r.firstPaymentDate, '2027-08-15');
  assert.equal(r.monthlyPaymentCents, 50000);
  assert.equal(r.totalPaidCents, 300000);
  assert.equal(r.finalInvestedCents, 2_000_000);
});

test('Schedule B, example 2: reinvested 12 months, every line of the table, then $672.44 a month', () => {
  const r = computeReturns({ ...B, years: 3, reinvestMonths: 12 });
  const table = [
    [50000, 2050000], [51250, 2101250], [52531, 2153781], [53845, 2207626], [55191, 2262817], [56570, 2319387],
    [57985, 2377372], [59434, 2436806], [60920, 2497726], [62443, 2560169], [64004, 2624173], [65604, 2689777]
  ];
  table.forEach(([ret, closing], i) => {
    assert.equal(r.months[i].returnCents, ret, `month ${i + 1} return`);
    assert.equal(r.months[i].closingCents, closing, `month ${i + 1} invested amount`);
    assert.equal(r.months[i].mode, 'reinvest');
  });
  assert.equal(r.months[11].month, '2028-06-01');
  assert.equal(r.months[12].mode, 'pay');
  assert.equal(r.months[12].returnCents, 67244);
  assert.equal(r.monthlyPaymentCents, 67244);
  assert.equal(r.firstPaymentDate, '2028-08-15');
});

test('a part month at each end is pro-rated by days, like the database', () => {
  // invested January 20, 2027: the Lockup End Date is July 20, July earns 12 of 31 days
  const r = computeReturns({ amountCents: 2_000_000, yearlyBps: 3000, investmentDate: '2027-01-20', years: 1, reinvestMonths: 0 });
  assert.equal(r.lockupEndDate, '2027-07-20');
  assert.equal(r.months[0].daysEarning, 12);
  assert.equal(r.months[0].returnCents, monthlyReturnCents(2_000_000, 3000, 12, 31));
  assert.equal(r.months[0].returnCents, 19355);
  // the year ends January 19, 2028: January earns 19 days
  assert.equal(r.endDate, '2028-01-19');
  assert.equal(r.months.at(-1)!.daysEarning, 19);
});

test('dates add like PostgreSQL intervals; helpers', () => {
  assert.equal(addMonths('2027-08-31', 6), '2028-02-29');
  assert.equal(addMonths('2027-01-31', 1), '2027-02-28');
  assert.equal(firstOfNextMonth('2026-12-09'), '2027-01-01');
  assert.equal(monthsBetween('2027-01-01', '2027-08-15'), 7.5);
  assert.equal(monthlyReturnCents(2_689_777, 3000, 31, 31), 67244);
});

test('always reinvested for 5 years: no cash, the amount grows every month after the lockup', () => {
  const r = computeReturns({ ...B, years: 5, reinvestMonths: Infinity });
  assert.equal(r.totalPaidCents, 0);
  assert.equal(r.months.length, 54);
  assert.equal(r.finalInvestedCents, r.months.at(-1)!.closingCents);
  assert.equal(r.finalInvestedCents, 2_000_000 + r.totalReinvestedCents);
  for (let k = 1; k < r.months.length; k++) assert.ok(r.months[k].returnCents >= r.months[k - 1].returnCents);
});
