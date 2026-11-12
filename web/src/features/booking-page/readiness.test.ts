import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { readyNext, READY_TARGET, readinessHref, readinessLines, readinessSummary, showReadiness } from './readiness.ts';

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

test('r38: What\'s left: each line jumps to its tab and section; the next step is the first not done', () => {
  const base = '/admin/bookings/CC-1';
  assert.equal(readinessHref('paid', base), '/admin/bookings/CC-1?tab=money#bk-money');
  assert.equal(readinessHref('agreement', base), '/admin/bookings/CC-1?tab=documents#bk-documents');
  assert.equal(readinessHref('offer', '/staff/bookings/CC-1'), '/staff/bookings/CC-1?tab=review#bk-review');
  for (const k of ['offer', 'paid', 'identity', 'coverage', 'deposit', 'drivers', 'agreement', 'prepare']) assert.ok(READY_TARGET[k], k);
  const lines = readinessLines({ status: 'pending_payment', dueCents: 1000, paidCents: 1000, readiness: { all_drivers_verified: true }, insurerBilled: false });
  assert.equal(readyNext(lines)?.key, 'coverage');
  // the ids the links land on are on the booking page
  const page = readFileSync(new URL('./BookingPage.tsx', import.meta.url), 'utf8');
  for (const id of new Set(Object.values(READY_TARGET).map((t) => t.anchor))) assert.ok(page.includes(`id="${id}"`), id);
});
