import { test } from 'node:test';
import assert from 'node:assert/strict';
import { kpiState, kpiTarget, kpiValue, type Kpi } from './model.ts';

test('KPI words: rates, counts, days and no cases', () => {
  const k = (x: Partial<Kpi>): Kpi => ({ key: 'k', label: 'L', value: 0, target: 0, unit: 'count', met: null, detail: null, ...x });
  assert.equal(kpiValue(k({ unit: 'pct', value: 50 })), '50%');
  assert.equal(kpiTarget(k({ unit: 'pct', target: 90 })), '90% or more');
  assert.equal(kpiTarget(k({ target: 40 })), '40 a week');
  assert.equal(kpiValue(k({ unit: 'days', value: 1 })), '1 day');
  assert.equal(kpiValue(k({ unit: 'pct', value: null })), 'no cases');
  assert.equal(kpiState(k({ met: false })), 'missed');
  assert.equal(kpiState(k({ met: null })), 'none');
});
