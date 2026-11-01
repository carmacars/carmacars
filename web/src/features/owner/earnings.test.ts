import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classOf, estimate, rateFor, type CalcData } from './earnings.ts';

const DATA: CalcData = {
  year: 2026,
  classes: [
    { code: 'economy', label: 'Economy', card_cents: 6200, avg_cents: 5500, n: 4 },
    { code: 'premium', label: 'Premium', card_cents: 10900, avg_cents: null, n: 0 },
    { code: 'luxury', label: 'Luxury', card_cents: 18900, avg_cents: 21000, n: 2 },
    { code: 'standard', label: 'Standard', card_cents: null, avg_cents: null, n: 0 }
  ],
  models: [{ make: 'mercedesbenz', model: 'c-class', class: 'premium', avg_cents: 13500, n: 3 }],
  rules: [
    { make: 'porsche', model_re: '^(911|cayman)', trim_re: null, body_re: null, class: 'luxury', aged_years: 12, aged_class: 'premium' },
    { make: 'mercedesbenz', model_re: null, trim_re: null, body_re: null, class: 'premium', aged_years: null, aged_class: null },
    { make: null, model_re: null, trim_re: null, body_re: 'sport utility|\\mvan\\M', class: 'suv', aged_years: null, aged_class: null },
    { make: 'kia', model_re: '^(rio|forte)', trim_re: null, body_re: null, class: 'economy', aged_years: null, aged_class: null }
  ],
  fees: { insurance_cents: null, tracker_cents: null }
};

test('the class: the first rule that fits, as the database picks it, aged down when old', () => {
  assert.equal(classOf(DATA.rules, { year: 2022, make: 'Porsche', model: '911 Carrera' }, 2026), 'luxury');
  assert.equal(classOf(DATA.rules, { year: 2010, make: 'Porsche', model: '911' }, 2026), 'premium');
  assert.equal(classOf(DATA.rules, { year: 2021, make: 'Kia', model: 'Forte' }, 2026), 'economy');
  assert.equal(classOf(DATA.rules, { year: 2021, make: 'Ford', model: 'Transit', body: 'Cargo Van' }, 2026), 'suv', 'Postgres word edges read as \\b');
  assert.equal(classOf(DATA.rules, { year: 2021, make: 'Mazda', model: '3' }, 2026), 'standard');
});

test('the rate: the same make and model first, then the class average, then the class rate card, never made up', () => {
  assert.deepEqual(rateFor(DATA, { year: 2023, make: 'Mercedes-Benz', model: 'C-Class' }).cents, 13500);
  assert.equal(rateFor(DATA, { year: 2023, make: 'Mercedes-Benz', model: 'C-Class' }).source, 'model');
  assert.deepEqual([rateFor(DATA, { year: 2021, make: 'Kia', model: 'Rio' }).cents, rateFor(DATA, { year: 2021, make: 'Kia', model: 'Rio' }).source], [5500, 'class']);
  assert.deepEqual([rateFor(DATA, { year: 2021, make: 'BMW', model: 'X3' }).cents, rateFor(DATA, { year: 2021, make: 'Mercedes-Benz', model: 'GLC' }).source], [null, 'card']);
  assert.deepEqual([rateFor(DATA, { year: 2021, make: 'Mazda', model: '3' }).cents, rateFor(DATA, { year: 2021, make: 'Mazda', model: '3' }).source], [null, 'none']);
});

test('the month: rate x days, the share, before fees when they are not set', () => {
  const e = estimate({ rateCents: 10000, days: 18, sharePct: 70, fees: DATA.fees });
  assert.deepEqual(e, { revenue: 180000, share: 126000, fees: null, net: 126000, yearly: 1512000, beforeFees: true });
});

test('the month less the fees when an Admin set them; the days stay between 0 and 28', () => {
  const e = estimate({ rateCents: 9000, days: 40, sharePct: 80, fees: { insurance_cents: 25000, tracker_cents: 2500 } });
  assert.equal(e.revenue, 252000);
  assert.equal(e.share, 201600);
  assert.equal(e.fees, 27500);
  assert.equal(e.net, 174100);
  assert.equal(e.yearly, 174100 * 12);
  assert.equal(e.beforeFees, false);
  assert.equal(estimate({ rateCents: 9000, days: 5, sharePct: 60, fees: { insurance_cents: 25000, tracker_cents: null } }).beforeFees, true, 'one fee missing: before fees');
});
