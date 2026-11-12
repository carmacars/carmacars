import { test } from 'node:test';
import assert from 'node:assert/strict';
import { changeText, coverageChoiceProblem, planText, resultText, whatHappens, type ProtectionOption } from './model.ts';

const opt = (o: Partial<ProtectionOption>): ProtectionOption => ({ option: 3, label: 'the CarmaCars Protection Plan', current: false, available: true, problem: null,
  applies: 'now', change_cents: 5650, new_total_cents: 50000, deposit_change_cents: 0, needs: '', ...o });

test('the price line of each option', () => {
  assert.equal(changeText(opt({})), '+$56.50');
  assert.equal(changeText(opt({ change_cents: -5650 })), '-$56.50');
  assert.equal(changeText(opt({ change_cents: 0 })), 'No price change');
  assert.equal(changeText(opt({ current: true })), 'Current');
});

test('the plan a day times the days', () => {
  assert.equal(planText({ plan_daily_cents: 1250, plan_cents: 5000, plan_hst_cents: 650, days: 4 }), '$12.50 a day x 4 days = $50.00 plus $6.50 HST');
  assert.equal(planText({ plan_daily_cents: null, plan_cents: null, plan_hst_cents: null, days: 4 }), '');
});

test('what happens: staff never charge by themselves, the renter pays on the page, leaving the plan is reviewed', () => {
  assert.match(whatHappens(opt({}), { status: 'confirmed', side: 'staff' }), /balance to collect.*nothing is charged/);
  assert.match(whatHappens(opt({}), { status: 'confirmed', side: 'renter' }), /You pay \$56\.50 more/);
  assert.match(whatHappens(opt({ option: 1, applies: 'review', change_cents: -5650 }), { status: 'confirmed', side: 'renter' }), /once approved/);
  assert.match(whatHappens(opt({ change_cents: -5650 }), { status: 'confirmed', side: 'staff' }), /refund for an Admin/);
});

test('the coverage order: card, then OPCF 27, then the plan (2541)', () => {
  const covered = { result: 'covered' as const, card_id: 'c', message: 'ok' };
  assert.match(coverageChoiceProblem(2, null, true, false) ?? '', /Pick your credit card/);
  assert.match(coverageChoiceProblem(2, { result: 'not_covered', card_id: 'c', message: 'No CDW.' }, true, false) ?? '', /No CDW\..*choose OPCF 27/);
  assert.match(coverageChoiceProblem(2, { result: 'review', card_id: 'c', message: 'Unknown.' }, true, false) ?? '', /Protection Plan/);
  assert.match(coverageChoiceProblem(2, covered, false, false) ?? '', /pay for the rental with this card/);
  assert.equal(coverageChoiceProblem(2, covered, true, false), null);
  assert.match(coverageChoiceProblem(1, null, false, false) ?? '', /upload your auto policy/);
  assert.equal(coverageChoiceProblem(1, null, false, true), null);
  assert.equal(coverageChoiceProblem(3, null, false, false), null);
});

test('the result line', () => {
  assert.equal(resultText({ applied: false }), 'Sent for review. We let you know as soon as it is checked.');
  assert.equal(resultText({ applied: true, to_label: 'the CarmaCars Protection Plan', total_before_cents: 10000, total_after_cents: 15650, open_cents: 5650 }),
    'Changed to the CarmaCars Protection Plan. Total $100.00 to $156.50. $56.50 open to pay.');
  assert.match(resultText({ applied: true, to_label: 'x', override: true }), /Admin override/);
});
