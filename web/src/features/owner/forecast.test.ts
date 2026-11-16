// r48 O (3081): the owner's forecast, the cars together and how each car's is made (features/owner/forecast.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { basisLine, pctOf, totals, type CarForecast } from './forecast.ts';

const car = (id: string, occ: number[], rev: number[]): CarForecast => ({ vehicle_id: id, name: id, from: '2026-12-01', history_months: 0, own_weight: 0, own_level_bps: null,
  day_cents: 9000, day_from: 'rate', months: occ.map((o, i) => ({ month: `2027-0${i + 1}-01`, curve_bps: o, own_bps: null, occupancy_bps: o, days: 30, revenue_cents: rev[i]! })) });

test('the cars together: occupancy averaged, revenue added up, month by month', () => {
  assert.deepEqual(totals({ cars: [car('a', [6000, 5000], [100, 200]), car('b', [4000, 7000], [50, 25])] }),
    [{ month: '2027-01-01', occupancy_bps: 5000, revenue_cents: 150 }, { month: '2027-02-01', occupancy_bps: 6000, revenue_cents: 225 }]);
  assert.deepEqual(totals({ cars: [] }), []);
  assert.equal(pctOf(6349), '63%');
});

test('each car says how its forecast is made', () => {
  assert.match(basisLine({ history_months: 2, own_weight: 0, day_from: 'rate' }), /GTA season only.*3 full months \(2 so far\).*daily rate/);
  assert.match(basisLine({ history_months: 6, own_weight: 0.667, day_from: 'statements' }), /own 6 months \(its own occupancy counts for 67%\).*own statements/);
});
