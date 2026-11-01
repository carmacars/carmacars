import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_INPUTS, baseFrom, investorsOnFile, readInputs, runModel, type ActualMonth, type Inputs } from './engine.ts';

// A launch month like October 2026: about $11,941 of rental earned over 106.2 rented days on 20 cars (illustrative).
const oct = (over: Partial<ActualMonth> = {}): ActualMonth => ({
  month: '2026-10-01', complete: true, rental_cents: 1_194_100, rental_insurer_cents: 755_300, rental_renter_cents: 438_800, rented_days: 106.2, rentals: 14, cars: 20,
  fees_cents: 119_410, fees_by_kind: {}, cash_by_method: {}, owner_share_cents: 600_000, partner_share_cents: 0, commissions_cents: 0, kickbacks_cents: 0, owner_payouts_paid_cents: 0,
  processing_cents: 0, expenses_cents: 0, expenses_by_category: {}, investor_payouts_cents: 0, investor_capital_cents: 0, ...over
});
const near = (a: number, b: number, msg = '') => assert.ok(Math.abs(a - b) < 1e-6, `${msg} got ${a}, want ${b}`);
const inp = (o: Partial<Inputs> = {}): Inputs => ({ ...DEFAULT_INPUTS, oneTime: [], hires: [], ...o });

test('the base month comes from the latest complete actual month: rate per rented day, utilization, fee and keep percentages', () => {
  const b = baseFrom([oct(), oct({ month: '2026-11-01', complete: false, rental_cents: 1 })], inp());
  assert.equal(b.month, '2026-10-01');
  near(b.ratePerDay, 11_941 / 106.2);
  near(b.util, 106.2 / (20 * 31));
  near(b.feePct, 0.1);
  near(b.companyKeepPct, (11_941 - 6000) / 11_941);
  assert.equal(b.source.ratePerDay, 'actual');
  const typed = baseFrom([oct()], inp({ ratePerDay: 150, utilStart: 0.4 }));
  assert.equal(typed.ratePerDay, 150); assert.equal(typed.util, 0.4); assert.equal(typed.source.util, 'input');
});

test('A then F: the actual month is the actual; the forecast ramps utilization and adds cars from it', () => {
  const m = runModel([oct()], inp({ utilTarget: 0.6, utilRampMonths: 6, carsAddedPerMonth: 1 }));
  assert.equal(m.months[0]!.kind, 'A');
  near(m.months[0]!.rental, 11_941);
  assert.equal(m.months[1]!.kind, 'F');
  assert.equal(m.months[1]!.k, 1);
  near(m.months[1]!.cars, 21);
  const u0 = 106.2 / 620;
  near(m.months[1]!.util, u0 + (0.6 - u0) / 6);
  near(m.months[6]!.util, 0.6);
  near(m.months[9]!.util, 0.6);
  const f = m.months[1]!;
  near(f.rentedDays, 21 * f.util * 30.4);
  near(f.rental, f.rentedDays * (11_941 / 106.2));
  near(f.netRevenue, f.rental * ((11_941 - 6000) / 11_941) + f.rental * 0.1);
  assert.equal(m.latestActual, '2026-10-01');
  assert.equal(m.months.length, 60);
  assert.equal(m.years.length, 5);
});

test('the month in progress is a forecast month even with actuals so far', () => {
  const m = runModel([oct(), oct({ month: '2026-11-01', complete: false })], inp());
  assert.equal(m.months[1]!.kind, 'F');
});

test('operating costs: actual expenses where entered, the assumption where not (estimated), the premium blank counts as $0 with a warning', () => {
  const a = oct({ expenses_by_category: { software: { label: 'Software', cents: 20_000 }, other: { label: 'Other', cents: 5_000 } } });
  const m = runModel([a], inp({ staff: 1000, marketing: 0, repairs: 0, other: 400 }));
  const x = m.months[0]!;
  near(x.opex.software, 200);
  near(x.opex.other, 50);
  near(x.opex.staff, 1000);
  assert.deepEqual(x.opexEstimated, ['staff']);
  near(x.opex.insurance, 0);
  assert.ok(m.warnings.some((w) => /premium is blank/.test(w)));
  const withPremium = runModel([a], inp({ insurancePremium: 24_000 }));
  near(withPremium.months[3]!.opex.insurance, 2000);
  assert.ok(!withPremium.warnings.some((w) => /premium is blank/.test(w)));
});

test('rates and costs grow once a year from the base; hires start in their month', () => {
  const m = runModel([oct()], inp({ rateGrowth: 0.1, costGrowth: 0.1, staff: 1000, hires: [{ role: 'VA', monthly: 500, start: '2027-03' }] }));
  near(m.months[12]!.ratePerDay, m.months[1]!.ratePerDay);       // k = 12, still year one of the forecast
  near(m.months[13]!.ratePerDay, m.months[1]!.ratePerDay * 1.1);  // k = 13
  near(m.months[4]!.opex.staff, 1000);                             // Feb 2027
  near(m.months[5]!.opex.staff, 1500);                             // Mar 2027
});

test('investor returns: investors on file after their lockup, planned raises after theirs; tax on what is left; cash carries', () => {
  const inv = [{ invested_cents: 5_000_000, yearly_bps: 3000, lockup_end_date: '2027-01-01', status: 'active' }];
  near(investorsOnFile(inv, '2026-12'), 0);
  near(investorsOnFile(inv, '2027-01'), 1250);
  const m = runModel([oct()], inp({ raises: [{ month: '2026-12', amount: 100_000 }], lockupMonths: 6, investorRate: 0.3, taxRate: 0.1, openingCash: 1000 }), inv);
  const dec = m.months[2]!, jun = m.months[8]!, jul = m.months[9]!;
  near(dec.raises, 100_000);
  near(jun.investorReturns, 1250);           // the raise is still locked up in June 2027
  near(jul.investorReturns, 1250 + 2500);    // from the 7th month after it
  near(jul.tax, Math.max(0, jul.ebitda - jul.investorReturns) * 0.1);
  near(m.months[0]!.openingCash, 1000);
  near(m.months[1]!.openingCash, m.months[0]!.closingCash);
  near(m.months[1]!.closingCash, m.months[0]!.closingCash + m.months[1]!.cashFlow);
});

test('break-even is the first month EBITDA stays at or above zero; the pro forma sums each 12 months', () => {
  const m = runModel([oct()], inp({ staff: 3000, utilTarget: 0.7, utilRampMonths: 12, carsAddedPerMonth: 2 }));
  const i = m.months.findIndex((x) => x.month === m.breakEven);
  assert.ok(i >= 0);
  assert.ok(m.months.slice(i).every((x) => x.ebitda >= 0));
  if (i > 0) assert.ok(m.months[i - 1]!.ebitda < 0);
  const y1 = m.years[0]!;
  near(y1.ebitda, m.months.slice(0, 12).reduce((s, x) => s + x.ebitda, 0));
  assert.equal(y1.actualMonths, 1);
  near(y1.closingCash, m.months[11]!.closingCash);
});

test('saved assumptions: numbers over the defaults, blanks stay blank, bad rows dropped', () => {
  const i = readInputs({ utilTarget: '0.65', insurancePremium: '', ratePerDay: null, staff: 'x', raises: [{ month: '2027-02', amount: 50000 }, { month: 'soon', amount: 1 }], hires: [] });
  assert.equal(i.utilTarget, 0.65);
  assert.equal(i.insurancePremium, null);
  assert.equal(i.staff, DEFAULT_INPUTS.staff);
  assert.deepEqual(i.raises, [{ month: '2027-02', amount: 50000 }]);
  assert.deepEqual(i.hires, []);
  assert.equal(readInputs({ insurancePremium: 18000 }).insurancePremium, 18000);
});
