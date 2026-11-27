import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bars, change, figure, headline, monthWords, type TractionMetric } from './traction.ts';

const m = (code: string, unit: string, months: Array<[string, number]>): TractionMetric => ({ code, label: code, unit, note: null, months: months.map(([month, value]) => ({ month, value })) });

test('r50 hotfix 2: the last full month, its change on the month before and the month in progress', () => {
  const web = m('mau_web', 'people', [['2026-09-01', 800], ['2026-10-01', 1000], ['2026-11-01', 400]]);
  assert.deepEqual(headline(web, '2026-11-27'), { month: '2026-10-01', value: 1000, changePct: 25, current: 400 });
  assert.equal(headline(m('x', 'days', []), '2026-11-27'), null);
  // only the month in progress: it is shown, with no change
  assert.deepEqual(headline(m('mau_app', 'people', [['2026-11-01', 12]]), '2026-11-27'), { month: '2026-11-01', value: 12, changePct: null, current: null });
  assert.equal(monthWords('2026-10-01'), 'October 2026');
  assert.equal(change(25), '+25% on the month before');
  assert.equal(change(-4), '-4% on the month before');
});

test('the same model for any business: merch items customized, phones purchased', () => {
  const merch = m('items_customized', 'items', [['2026-10-01', 12500], ['2026-11-01', 300]]);
  assert.equal(figure(headline(merch, '2026-11-27')!.value, merch.unit), '13K');
  assert.equal(figure(37.5, 'days'), '37.5');
  assert.equal(figure(412.4, 'days'), '412');
  assert.deepEqual(bars(m('phones_purchased', 'phones', [['2026-09-01', 5], ['2026-10-01', 10]])), [50, 100]);
});
