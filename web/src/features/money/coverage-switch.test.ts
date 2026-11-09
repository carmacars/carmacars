import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardPreview, planPreview, resultText, type SwitchState } from './coverage-switch.ts';

const state = (o: Partial<SwitchState> = {}): SwitchState => ({
  booking_number: 'CC-10001', status: 'confirmed', option: 2, option_label: 'rental coverage on your credit card', may: true, why_not: null, is_offer: false,
  to_plan: { available: true, problem: null, amount_cents: 4000, hst_cents: 520, total_cents: 4520, new_total_cents: 33900 },
  to_card: { available: false, problem: 'This booking is not on the Protection Plan', option: 2, option_label: 'rental coverage on your credit card', plan_paid: false, removes_cents: 0 },
  total_cents: 29380, open_cents: 0, history: [], ...o,
});

test('the plan preview names the price, the new total and what happens', () => {
  const t = planPreview(state());
  assert.match(t, /\$40\.00 plus \$5\.20 HST/);
  assert.match(t, /\$293\.80 to \$339\.00/);
  assert.match(t, /open to collect/);
});

test('an offer is sent again instead', () => {
  assert.match(planPreview(state({ status: 'offered' })), /sent again with the new price/);
  assert.doesNotMatch(planPreview(state({ status: 'offered' })), /open to collect/);
});

test('nothing is said when the plan has no price', () => {
  assert.equal(planPreview(state({ to_plan: { available: false, problem: 'no price', amount_cents: null, hst_cents: null, total_cents: null, new_total_cents: null } })), '');
});

test('going back says when a paid plan is refunded', () => {
  const t = cardPreview(state({ option: 3, to_card: { available: true, problem: null, option: 2, option_label: 'rental coverage on your credit card', plan_paid: true, removes_cents: 4520 } }));
  assert.match(t, /\$45\.20 with HST\) comes off: it was paid, so a refund/);
  assert.match(t, /goes back to rental coverage on your credit card/);
});

test('the result line', () => {
  const r = { direction: 'to_plan' as const, was: 'confirmed', status: 'confirmed', total_before_cents: 29380, total_after_cents: 33900, difference_cents: 4520, open_cents: 4520, offer_version: null, refund_id: null, tasks_cleared: 1, restored: 0 };
  assert.equal(resultText(r), 'Switched to the Protection Plan. Total $293.80 to $339.00. $45.20 to collect: use Collect on this tab.');
  assert.match(resultText({ ...r, was: 'offered', offer_version: 2, open_cents: 0 }), /new offer \(version 2\)/);
  assert.match(resultText({ ...r, direction: 'to_card', open_cents: 0, refund_id: 'x' }), /Switched to card coverage.*A refund waits for an Admin/);
});
