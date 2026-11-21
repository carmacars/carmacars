// Staff rewards (3261): the words and sums of the My rewards card.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { codeDayOptions, endingSoon, fill, headline, pct, progressLine, tierFill, tierLine, type StaffRewards } from './model.ts';

const r = (over: Partial<StaffRewards> = {}): StaffRewards => ({
  member: true, eligible: true, frozen: false, why_not: null, sales: true, field: false, has_renter: true,
  discount: { bps: 1500, code: 'STAFFABC1234', tier: 'member', tier_name: 'Member' },
  month: { label: 'November', days: 32, last_days: 10, next: { name: 'Silver', at: 50, left: 18 } },
  progress: { sales: { label: 'Rental days booked', per: 100, total: 132, toward: 32, left: 68 } },
  free_days: { balance: 1, lots: [{ days: 1, left: 1, expires_on: '2026-12-01', earned_on: '2026-06-01', source: 'Rental days booked' }], codes: [] },
  ...over
});

test('percentages and bars', () => {
  assert.equal(pct(1500), '15%');
  assert.equal(pct(1250), '12.5%');
  assert.equal(fill(32, 100), 0.32);
  assert.equal(fill(140, 100), 1);
  assert.equal(fill(5, 0), 0);
  assert.equal(tierFill(r()), 0.64);
  assert.equal(tierFill(r({ month: { label: 'November', days: 120, last_days: 0, next: null } })), 1);
});

test('the lines say how far the next free day and the next tier are', () => {
  assert.equal(progressLine(r().progress!.sales!), '32 of 100 rental days: 68 rental days to your next free day.');
  assert.equal(progressLine({ label: 'Handovers completed', per: 100, total: 99, toward: 99, left: 1 }), '99 of 100 handovers: 1 handover to your next free day.');
  assert.equal(tierLine(r()), '32 rental days booked in November: 18 more to Silver.');
  assert.match(tierLine(r({ month: { label: 'November', days: 120, last_days: 0, next: null }, discount: { bps: 2500, code: 'X', tier: 'gold', tier_name: 'Gold' } })), /top tier: 25% off/);
});

test('the head: the discount and the free days, or why there are none', () => {
  assert.equal(headline(r()), '15% off your own rentals and 1 free day to use');
  assert.equal(headline(r({ free_days: { balance: 0, lots: [], codes: [] } })), '15% off your own rentals');
  assert.equal(headline(r({ eligible: false, frozen: true })), 'Your perks are frozen');
  assert.equal(headline(r({ eligible: false, discount: undefined })), 'Rental perks are not on for this account');
});

test('a code takes 1 to 7 days, never more than the balance; days ending within 30 days are named', () => {
  assert.deepEqual(codeDayOptions(0), []);
  assert.deepEqual(codeDayOptions(2), [1, 2]);
  assert.equal(codeDayOptions(12).length, 7);
  assert.equal(endingSoon(r().free_days!.lots, '2026-11-20').length, 1);
  assert.equal(endingSoon(r().free_days!.lots, '2026-10-01').length, 0);
  assert.equal(endingSoon([{ days: 1, left: 0, expires_on: '2026-11-25', earned_on: '2026-05-25', source: 'x' }], '2026-11-20').length, 0);
});
