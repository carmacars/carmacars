import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DAYS, MONTHS, SEASON, classOf, rateFor, seasonal, startDays, type CalcData } from './earnings.ts';

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

// ---------------------------------------------------------------- r48 ops (3291): conservative and seasonal
test('conservative from the start: 12 rented days in an average month (Program settings), never 18; at most 22', () => {
  assert.equal(DAYS.start, 12);
  assert.ok(DAYS.max <= 22);
  assert.equal(startDays(null), 12);
  assert.equal(startDays({ base_days: 9 }), 9);
  assert.equal(startDays({ base_days: 40 }), 22);
  assert.equal(startDays({ base_days: 1 }), 4);
});

test('the GTA season: summer busiest, winter slow, the shoulder months slowest', () => {
  const summer = Math.min(SEASON.jun!, SEASON.jul!, SEASON.aug!), winter = [SEASON.dec!, SEASON.jan!, SEASON.feb!], shoulder = [SEASON.mar!, SEASON.apr!, SEASON.oct!, SEASON.nov!];
  assert.ok(summer > Math.max(...winter), 'summer above winter');
  assert.ok(Math.max(...shoulder) <= Math.min(...winter), 'the shoulder months at or under winter');
  assert.ok(Math.min(...shoulder) < Math.min(...winter), 'the slowest month is a shoulder month');
  assert.ok(MONTHS.reduce((n, m) => n + SEASON[m]!, 0) / 12 < 1, 'a year is less than twelve average months');
});

test('a year is its twelve months added up, each at the season and the discounted rate; never twelve of the best month', () => {
  const s = seasonal({ rateCents: 10000, days: 12, sharePct: 70, fees: DATA.fees });
  assert.equal(s.dayCents, 8500, 'the listed rate less 15%');
  assert.deepEqual(s.months.map((m) => m.days), [9, 9, 8, 8, 10, 13, 16, 16, 10, 8, 8, 10]);
  assert.equal(s.months[6]!.revenue, 8500 * 16);
  assert.equal(s.months[6]!.share, Math.round(8500 * 16 * 0.7));
  assert.equal(s.yearly, Math.round(s.months.reduce((n, m) => n + m.net, 0) / 100) * 100);
  assert.equal(s.average, Math.round(s.yearly / 12 / 100) * 100);
  assert.deepEqual([s.busy.name, s.slow.name], ['August', 'April']);
  assert.ok(s.yearly < s.busy.net * 12);
  // far under what the page said before for the same car (18 days at the full rate, twelve times)
  const before = 10000 * 18 * 0.7 * 12;
  assert.ok(s.yearly < before * 0.6, `${s.yearly} against ${before}`);
  assert.equal(s.beforeFees, true); assert.equal(s.short, 0);
  // one fee missing: still before fees, none made up
  assert.equal(seasonal({ rateCents: 9000, days: 5, sharePct: 60, fees: { insurance_cents: 25000, tracker_cents: null } }).beforeFees, true);
});

test('with the fees set: each month less the fees, and the months that fall short are counted', () => {
  const s = seasonal({ rateCents: 6000, days: 6, sharePct: 70, fees: { insurance_cents: 25000, tracker_cents: 2500 } });
  assert.equal(s.fees, 27500);
  assert.equal(s.months[3]!.days, 4);
  assert.equal(s.months[3]!.net, Math.round(5100 * 4 * 0.7) - 27500);
  assert.ok(s.short >= 8, `${s.short} months short`);
  assert.ok(s.slow.net < 0);
});

test('an Admin\'s own season and discount are used; a month never has more rented days than it has, nor more than 26', () => {
  const flat = Object.fromEntries(MONTHS.map((m) => [m, 1]));
  const s = seasonal({ rateCents: 10000, days: 22, sharePct: 100, fees: DATA.fees, season: { ...flat, feb: 2.5, jul: 2 }, discountPct: 0 });
  assert.equal(s.dayCents, 10000);
  assert.equal(s.months[1]!.days, 26);
  assert.equal(s.months[6]!.days, 26);
  assert.equal(s.months[0]!.days, 22);
  assert.equal(seasonal({ rateCents: 10000, days: 12, sharePct: 70, fees: DATA.fees, season: { jan: 0 }, discountPct: 99 }).discountPct, 60);
});
