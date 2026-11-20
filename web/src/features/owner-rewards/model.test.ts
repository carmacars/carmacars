// Owner rewards (3262): the words and sums of the Rewards tab.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addressProblem, dollars, headline, milestoneFill, milestoneState, pct, type Milestone, type OwnerRewards } from './model.ts';

const kit = (over: Partial<Milestone> = {}): Milestone => ({ kind: 'merch_kit', name: 'CarmaCars merch kit', months: 6, reached: false, months_left: 2, request: null, ...over });

test('money and percentages as the owner reads them', () => {
  assert.equal(pct(2000), '20%');
  assert.equal(dollars(10000), '$100');
  assert.equal(dollars(2550), '$25.50');
});

test('a milestone: waiting, ready to redeem (never automatic), redeemed, shipped', () => {
  assert.deepEqual(milestoneState(kit()), { state: 'waiting', line: '2 more months to go.' });
  assert.equal(milestoneState(kit({ months_left: 1 })).line, '1 more month to go.');
  assert.equal(milestoneState(kit({ reached: true, months_left: 0 })).state, 'ready');
  const asked = milestoneState(kit({ reached: true, request: { id: 'x', status: 'requested', requested_at: '2026-11-20T15:00:00Z', shipped_at: null, tracking: null, city: 'Toronto' } }));
  assert.equal(asked.state, 'requested');
  assert.match(asked.line, /getting it ready to ship to Toronto/);
  const sent = milestoneState(kit({ reached: true, request: { id: 'x', status: 'shipped', requested_at: '2026-11-20T15:00:00Z', shipped_at: '2026-11-22T15:00:00Z', tracking: 'CP123', city: 'Toronto' } }));
  assert.equal(sent.state, 'shipped');
  assert.match(sent.line, /^Shipped Nov 22, 2026 to Toronto\. Tracking: CP123$/);
  assert.equal(milestoneFill(3, kit()), 0.5);
  assert.equal(milestoneFill(9, kit({ reached: true })), 1);
});

test('the address is confirmed before a kit is redeemed', () => {
  assert.equal(addressProblem({ name: '', line1: '1 Test Lane', city: 'Toronto', postal_code: 'M5V 1A1' }), 'Enter the name on the parcel.');
  assert.equal(addressProblem({ name: 'Daniel Rossi', line1: '', city: 'Toronto', postal_code: 'M5V 1A1' }), 'Enter the street address.');
  assert.match(addressProblem({ name: 'Daniel Rossi', line1: '1 Test Lane', city: 'Toronto', postal_code: '12' })!, /postal code/);
  assert.equal(addressProblem({ name: 'Daniel Rossi', line1: '1 Test Lane', city: 'Toronto', postal_code: 'm5v1a1' }), null);
});

test('the first line says what the owner has', () => {
  const r: OwnerRewards = { on: true, fleet: { bps: 2000, code: 'OWNERABC', car_down_now: false, cars: [] }, friends: { bps: 1000, kickback_bps: 2000, code: 'OF6ECFDE', link: 'https://carmacars.ca/r/OF6ECFDE', rentals: 0, earned_cents: 0, recent: [] },
    milestones: [kit({ reached: true, months_left: 0 })] };
  assert.equal(headline(r), '20% off other CarmaCars cars while yours is out, 10% off for your friends and family, and a merch kit ready to redeem.');
  assert.equal(headline({ on: false, why: 'Owner rewards are for owners in the Vehicle Owner Program.' }), 'Owner rewards are for owners in the Vehicle Owner Program.');
});
