import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DAYS, MONTHS, SEASON, TARGET, calcClass, classOf, estimate, monthlyAt, occupancyDays, type CalcData } from './earnings.ts';

// The rules as the database seeds them (vehicle_class_rules) and as production has them: a make rule for Acura, the SUV body rule.
const DATA: CalcData = {
  year: 2026,
  classes: [
    { code: 'economy', label: 'Economy', card_cents: 6200, avg_cents: 5500, n: 4 }, { code: 'standard', label: 'Standard', card_cents: 8900, avg_cents: null, n: 0 },
    { code: 'premium', label: 'Premium', card_cents: 10900, avg_cents: null, n: 0 }, { code: 'luxury', label: 'Luxury', card_cents: 18900, avg_cents: 21000, n: 2 },
    { code: 'suv', label: 'SUV', card_cents: 8900, avg_cents: null, n: 0 }
  ],
  models: [{ make: 'acura', model: 'rdx', class: 'premium', avg_cents: 16000, n: 2 }],
  rules: [
    { make: 'porsche', model_re: '^(911|cayman)', trim_re: null, body_re: null, class: 'luxury', aged_years: 12, aged_class: 'premium' },
    { make: 'acura', model_re: null, trim_re: null, body_re: null, class: 'premium', aged_years: null, aged_class: null },
    { make: null, model_re: null, trim_re: null, body_re: 'sport utility|suv|crossover|\\mvan\\M', class: 'suv', aged_years: null, aged_class: null },
    { make: 'kia', model_re: '^(rio|forte)', trim_re: null, body_re: null, class: 'economy', aged_years: null, aged_class: null }
  ],
  fees: { insurance_cents: null, tracker_cents: null }, target: TARGET
};

test('the class: the first rule that fits, as the database picks it, aged down when old', () => {
  assert.equal(classOf(DATA.rules, { year: 2022, make: 'Porsche', model: '911 Carrera' }, 2026), 'luxury');
  assert.equal(classOf(DATA.rules, { year: 2010, make: 'Porsche', model: '911' }, 2026), 'premium');
  assert.equal(classOf(DATA.rules, { year: 2021, make: 'Kia', model: 'Forte' }, 2026), 'economy');
  assert.equal(classOf(DATA.rules, { year: 2021, make: 'Ford', model: 'Transit', body: 'Cargo Van' }, 2026), 'suv', 'Postgres word edges read as \\b');
  assert.equal(classOf(DATA.rules, { year: 2021, make: 'Mazda', model: '3' }, 2026), 'standard');
});

test('5141: an old car of a premium make is priced as the car under the make, not as premium', () => {
  assert.equal(calcClass(DATA, { year: 2015, make: 'Acura', model: 'RDX' }), 'standard');
  assert.equal(calcClass(DATA, { year: 2015, make: 'Acura', model: 'RDX', body: 'Sport Utility Vehicle (SUV)' }), 'suv');
  assert.equal(calcClass(DATA, { year: 2023, make: 'Acura', model: 'RDX' }), 'premium', 'a recent one stays premium');
  assert.equal(calcClass(DATA, { year: 2010, make: 'Porsche', model: '911' }), 'standard', 'aged twice: luxury, premium by its rule, then the car under the make');
});

test('5141: the owner\'s rule: a typical car about $1,200 a month at 80%, never under $800, more for newer and higher demand', () => {
  assert.equal(occupancyDays(DATA), 24, '80% of a 30-day month');
  const typical = monthlyAt(DATA, { year: 2021, make: 'Mazda', model: '3' });
  assert.equal(typical.cents, 120000, 'a five-year-old standard car is the typical car');
  const rdx = monthlyAt(DATA, { year: 2015, make: 'Acura', model: 'RDX' });
  const crv = monthlyAt(DATA, { year: 2025, make: 'Honda', model: 'CR-V', body: 'SUV' });
  assert.ok(rdx.cents < crv.cents, `a 2015 RDX (${rdx.cents}) earns less than a 2025 CR-V (${crv.cents})`);
  assert.deepEqual([rdx.cls, rdx.cents, crv.cls, crv.cents], ['standard', 84000, 'suv', 158400]);
  const old = monthlyAt(DATA, { year: 2006, make: 'Kia', model: 'Rio' });
  assert.deepEqual([old.cents, old.floored], [80000, true], 'never under the floor');
  assert.ok(monthlyAt(DATA, { year: 2026, make: 'Mazda', model: '3' }).cents > typical.cents, 'newer earns more');
  assert.ok(monthlyAt(DATA, { year: 2021, make: 'Mazda', model: 'CX-5', body: 'SUV' }).cents > typical.cents, 'higher demand earns more');
  assert.equal(monthlyAt(DATA, { make: 'Mazda', model: '3' }).cents, 120000, 'no year: the typical age');
});

test('5141: the year by month averages the month at the occupancy and the typical share; days and share move it', () => {
  const at = 120000;
  const e = estimate({ at, days: 24, occupancyDays: 24, sharePct: 70, fees: DATA.fees });
  assert.ok(Math.abs(e.average - at) <= 500, `average ${e.average}`);
  assert.equal(e.yearly, Math.round(e.months.reduce((n, m) => n + m.net, 0) / 100) * 100);
  assert.deepEqual([e.busy.name, e.slow.name], ['August', 'April'], 'summer busiest, the shoulder months slowest');
  assert.ok(e.months.every((m) => m.days <= 26));
  const half = estimate({ at, days: 12, occupancyDays: 24, sharePct: 70, fees: DATA.fees });
  assert.ok(Math.abs(half.average - at / 2) <= 500, `half the days, half the month: ${half.average}`);
  const more = estimate({ at, days: 24, occupancyDays: 24, sharePct: 80, fees: DATA.fees });
  assert.ok(Math.abs(more.average - Math.round(at * 80 / 70)) <= 500, `a larger share: ${more.average}`);
  assert.equal(e.revenueAverage, Math.round(e.shareAverage / 0.7 / 100) * 100);
  assert.equal(e.beforeFees, true);
  assert.ok(e.listedCents > 0);
});

test('with the fees set: each month less the fees, and the months that fall short are counted', () => {
  const s = estimate({ at: 80000, days: 6, occupancyDays: 24, sharePct: 70, fees: { insurance_cents: 25000, tracker_cents: 2500 } });
  assert.equal(s.fees, 27500);
  assert.ok(s.short >= 6, `${s.short} months short`);
  assert.ok(s.slow.net < 0);
});

test('the GTA season default: summer busiest, the shoulder months slowest; the slider stops at 26 days', () => {
  assert.ok(Math.min(SEASON.jun!, SEASON.jul!, SEASON.aug!) > Math.max(SEASON.dec!, SEASON.jan!, SEASON.feb!));
  assert.ok(Math.min(SEASON.mar!, SEASON.apr!, SEASON.oct!, SEASON.nov!) < Math.min(SEASON.dec!, SEASON.jan!, SEASON.feb!));
  assert.equal(DAYS.max, 26);
  assert.equal(MONTHS.length, 12);
});
