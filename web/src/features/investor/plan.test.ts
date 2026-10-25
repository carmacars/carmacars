import { test } from 'node:test';
import assert from 'node:assert/strict';
import { estimateMonth, investorPlan, type Investment, type ReturnRow } from './plan.ts';

// The investor home's figures: their own statements first, estimates (the agreement's formula) only where no statement is.
const x: Investment = { id: 'i', principal_cents: 5000000, reinvested_cents: 0, redeemed_cents: 0, invested_amount_cents: 5000000, yearly_bps: 3000, investment_date: '2025-09-01',
  lockup_end_date: '2026-03-01', status: 'active', mode: 'pay', next_payment_date: '2026-11-15' };
const row = (m: string, status: string): ReturnRow => ({ id: m, return_month: `${m}-01`, opening_invested_cents: 5000000, days_earning: 30, days_in_month: 30, return_cents: 125000, disposition: 'pay', payment_date: `${m}-15`, status });

test('a full month at 30% on $50,000 is $1,250.00; nothing inside the lockup; a part month by days', () => {
  assert.equal(estimateMonth(x, '2026-10'), 125000);
  assert.equal(estimateMonth(x, '2026-02'), 0);
  assert.equal(estimateMonth({ ...x, lockup_end_date: '2026-04-16' }, '2026-04'), Math.round((5000000 * 3000 * 15) / (120000 * 30)));
});

test('paid to date, the next payment from an open statement, then estimates', () => {
  const rows = [row('2026-08', 'paid'), row('2026-09', 'accrued')].map((r, i) => ({ ...r, payment_date: i ? '2026-10-30' : '2026-09-15' }));
  const p = investorPlan({ investments: [x] }, rows, '2026-10-24');
  assert.equal(p.investedCents, 5000000); assert.equal(p.paidCents, 125000); assert.equal(p.earnedCents, 250000);
  assert.deepEqual(p.next, { date: '2026-10-30', cents: 125000, estimated: false });
  assert.deepEqual(p.schedule.map((s) => [s.title, s.state, s.estimated]), [['Return for August 2026', 'done', false], ['Return for September 2026', 'now', false],
    ['Return for October 2026', 'future', true], ['Return for November 2026', 'future', true], ['Return for December 2026', 'future', true]]);
  assert.equal(p.chart.labels.length, p.chart.returns.length);
  const none = investorPlan({ investments: [x] }, [], '2026-10-24');
  assert.deepEqual(none.next, { date: '2026-11-15', cents: 125000, estimated: true });
});
