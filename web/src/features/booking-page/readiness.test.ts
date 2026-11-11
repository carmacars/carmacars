import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readinessLines, readinessSummary, showReadiness } from './readiness.ts';

test('the get-ready checklist: each line done or not, from the booking\'s facts', () => {
  const lines = readinessLines({ status: 'confirmed', dueCents: 50000, paidCents: 50000, insurerBilled: false,
    readiness: { all_drivers_verified: true, coverage_confirmed: false, deposit_ok: true, additional_drivers_accepted: true, agreement_completed: false },
    addons: { total: 2, ticked: 1 } });
  assert.deepEqual(lines.map((l) => `${l.key}:${l.done}`), ['offer:true', 'paid:true', 'identity:true', 'coverage:false', 'deposit:true', 'drivers:true', 'agreement:false', 'prepare:false']);
  assert.equal(readinessSummary(lines), '5 of 8 ready');
});

test('a booking with nothing missing is good to go; no add-ons, no add-on line', () => {
  const lines = readinessLines({ status: 'confirmed', dueCents: 0, paidCents: 0, insurerBilled: true,
    readiness: { all_drivers_verified: true, coverage_confirmed: true, deposit_waived: true, agreement_completed: true } });
  assert.equal(lines.some((l) => l.key === 'prepare'), false);
  assert.match(readinessSummary(lines), /^Good to go/);
});

test('shown while the booking is arranged and before the pickup', () => {
  assert.deepEqual(['requested', 'offered', 'pending_payment', 'confirmed', 'on_rent'].map(showReadiness), [false, true, true, true, false]);
});
