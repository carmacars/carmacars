import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nextAction, newlyDone, stageSummary, stages } from './next-action.ts';
import type { NextStep, Progress } from './status.ts';
import type { BookingSummary } from './types.ts';
import type { StillNeeded } from './still-needed.ts';

// r40: "Do this next" picks one action from the rules that exist (nextStep, still needed, the balance, the trip times).
const NOW = Date.parse('2026-11-12T15:00:00Z');
const b = (o: Partial<BookingSummary> = {}): BookingSummary => ({
  id: 'b1', booking_number: 'CC-1001', status: 'confirmed', booking_type: 'standard', vehicle_id: 'v1', vehicle_year: 2024, vehicle_make: 'Toyota', vehicle_model: 'Corolla',
  vehicle_colour: null, slug: null, pickup_at: '2026-11-14T15:00:00Z', return_at: '2026-11-17T15:00:00Z', pickup_place: null, return_place: null,
  pickup_method: 'office', return_method: 'office', billable_days: 3, offer_expires_at: null, current_offer_version: 1, offer_approved_version: 1,
  total_due_at_booking_cents: 0, renter_due_at_booking_cents: 0, deposit_cents: 0, hst_at_booking_cents: 0, subtotal_at_booking_cents: 0, insurer_pays_cents: 0,
  coverage_option: null, coverage_confirmed_at: null, confirmed_at: null, handed_over_at: null, checked_in_at: null, request_note: null, km_allowance_total: null,
  overage_cents_per_km: null, deductible_cents: null, agreement_number: null, requested_at: null, booked_at: null, ...o
});
const calm: NextStep = { title: 'You are all set', note: 'Pickup soon.', href: '/account/bookings/CC-1001', cta: 'Pickup details' };
const places = { pickupPlace: '1 Example St', returnPlace: '1 Example St', now: NOW };
const needs = (status: 'missing' | 'rejected' | 'done', reason: string | null = null): StillNeeded => ({
  items: [{ key: 'licence', label: 'Driver licence photos', status, reason, action: { label: 'Upload', path: 'verify' } }], done: status === 'done' ? 1 : 0, total: 1, complete: status === 'done'
});

test('an urgent step comes first, with its button primary and a pickup countdown', () => {
  const step: NextStep = { title: 'Sign and pay', note: 'Two steps left.', href: '/account/bookings/CC-1001/checkout', cta: 'Sign and pay $100.00', urgent: true };
  const a = nextAction(b({ status: 'pending_payment' }), step, { ...places, needs: needs('missing') });
  assert.equal(a.kind, 'sign-pay');
  assert.equal(a.actions[0]!.href, '/account/bookings/CC-1001/checkout');
  assert.equal(a.actions[0]!.primary, true);
  assert.equal(a.urgent, true);
  assert.equal(a.deadline?.label, 'Pickup');
  assert.equal(a.deadline?.initial, 'Pickup in 2 days');
});

test('a balance owing comes before the checklist', () => {
  const a = nextAction(b(), calm, { ...places, balanceCents: 2500, needs: needs('missing') });
  assert.equal(a.kind, 'pay-balance');
  assert.equal(a.actions.find((x) => x.primary)?.label, 'Pay $25.00');
});

test('the first item still needed becomes the action; a rejected one says to send it again with the reason', () => {
  const a = nextAction(b(), calm, { ...places, needs: needs('rejected', 'The photo is blurry') });
  assert.equal(a.kind, 'verify');
  assert.equal(a.headline, 'Send your driver licence photos again');
  assert.match(a.detail ?? '', /blurry/);
  assert.equal(a.actions[0]!.href, '/account/bookings/CC-1001/verify');
  assert.equal(a.actions.filter((x) => x.primary).length, 1);
});

test('nothing to do: pick up the car, then return it, late is urgent', () => {
  const p = nextAction(b(), calm, { ...places, needs: needs('done') });
  assert.equal(p.kind, 'pickup');
  assert.match(p.headline, /^Pick up the 2024 Toyota Corolla/);
  const r = nextAction(b({ status: 'on_rent', return_at: '2026-11-12T13:00:00Z' }), { title: 'Return', note: '', href: '/account/bookings/CC-1001', cta: 'Return details' }, places);
  assert.equal(r.kind, 'return');
  assert.equal(r.deadline?.late, true);
  assert.equal(r.urgent, true);
  assert.equal(r.deadline?.initial, 'Return was due 2 h ago');
});

test('an offer ending within a day is urgent; a complete rental asks for a review', () => {
  const o = nextAction(b({ status: 'offered', offer_expires_at: '2026-11-12T20:00:00Z' }), { title: 'Approve your offer', note: '', href: '/account/bookings/CC-1001/offer', cta: 'Review offer', urgent: true }, places);
  assert.equal(o.kind, 'offer');
  assert.equal(o.deadline?.soon, true);
  const r = nextAction(b({ status: 'closed' }), { title: 'Rental complete', note: '', href: '/account/documents', cta: 'Documents' }, { ...places, reviewDue: true });
  assert.equal(r.kind, 'review');
  assert.equal(r.actions[0]!.href, '/account/bookings/CC-1001/review');
  assert.equal(nextAction(b({ status: 'closed' }), calm, places).kind, 'done');
});

const prog = (done: string[], href: Record<string, string> = {}): Progress[] =>
  ['Request sent', 'Offer approved', 'Agreement signed', 'Paid', 'Drivers verified', 'Coverage confirmed', 'Pickup', 'Return', 'Statement']
    .map((label) => ({ label, done: done.includes(label), href: href[label] }));

test('stages: done, one now, the rest later; the summary in words', () => {
  const s = stages(prog(['Request sent', 'Offer approved', 'Agreement signed'], { Paid: '/x/checkout' }));
  assert.deepEqual(s.map((x) => x.state), ['done', 'now', 'later', 'later', 'later', 'later']);
  assert.equal(s[1]!.href, '/x/checkout');
  assert.equal(s[1]!.yours, true);
  assert.equal(stageSummary(s).text, 'Step 2 of 6: Sign and pay');
  const all = stages(prog(['Request sent', 'Offer approved', 'Agreement signed', 'Paid', 'Drivers verified', 'Coverage confirmed', 'Pickup', 'Return', 'Statement']));
  assert.equal(stageSummary(all).text, 'All steps done');
});

test('a stage done out of order stays done; newly done compares with what was seen', () => {
  const s = stages(prog(['Request sent', 'Offer approved', 'Drivers verified', 'Coverage confirmed']));
  assert.deepEqual(s.map((x) => x.state), ['done', 'now', 'done', 'later', 'later', 'later']);
  assert.deepEqual(newlyDone(s, ['offer']), ['verify']);
  assert.deepEqual(newlyDone(s, null), []);
});

test('a booked rental has its offer behind it; after pickup every earlier stage is behind', () => {
  assert.equal(stages(prog(['Request sent', 'Paid', 'Agreement signed']), 'confirmed')[0]!.state, 'done');
  const s = stages(prog(['Request sent', 'Paid', 'Pickup']), 'on_rent');
  assert.deepEqual(s.map((x) => x.state), ['done', 'done', 'done', 'done', 'now', 'later']);
});
