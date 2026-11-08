// The Admin override, the past trip and the requests waiting (0770): what the booking page and the field job show.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { overrideView, requestLine, type OverrideRead } from './override.ts';

const base: OverrideRead = { booking_id: 'b', booking_number: 'CC-1', status: 'confirmed', kind: 'pickup', admin: true, blockers: [], problem: null, past_trip: false,
  pickup_at: '2026-10-31T14:00:00Z', return_at: '2026-11-03T14:00:00Z', requests: [] };
const deposit = { code: 'deposit', label: 'The deposit is not taken' };

test('nothing blocks and nothing waits: no card', () => {
  assert.equal(overrideView(base).show, false);
  assert.equal(overrideView(null).show, false);
});

test('an Admin overrides and records; staff ask an Admin, from the same card', () => {
  const a = overrideView({ ...base, blockers: [deposit] });
  assert.equal(a.show && a.blocked, true);
  assert.equal(a.overrideLabel, 'Override and record the pickup');
  const s = overrideView({ ...base, admin: false, blockers: [deposit] });
  assert.equal(s.overrideLabel, 'Ask an Admin to override the pickup');
  assert.match(s.overrideDone, /time you entered/);
  assert.equal(overrideView({ ...base, kind: 'return', status: 'on_rent', blockers: [{ code: 'odometer', label: 'x' }] }).overrideLabel, 'Override and record the return');
});

test('a refusal no override passes shows no override button', () => {
  assert.equal(overrideView({ ...base, blockers: [deposit], problem: 'placeholder' }).blocked, false);
});

test('a request waiting: an Admin approves or declines, the requester cancels, and no second request button', () => {
  const q = { id: 'q', action: 'pickup' as const, status: 'requested', reason: 'Renter at the lot', requested_at: '', requested_by: 'Fay Fleet', mine: true, checks: [deposit] };
  const a = overrideView({ ...base, blockers: [deposit], requests: [q] });
  assert.equal(a.requests[0]!.canDecide, true);
  assert.equal(a.blocked, false);
  const s = overrideView({ ...base, admin: false, blockers: [deposit], requests: [q] });
  assert.equal(s.requests[0]!.canDecide, false);
  assert.equal(s.requests[0]!.canCancel, true);
  assert.equal(requestLine(q), 'Fay Fleet asks to override the pickup: Renter at the lot. It passes: the deposit is not taken.');
});

test('a past trip: offered while both times passed, not twice', () => {
  const v = overrideView({ ...base, past_trip: true });
  assert.equal(v.show && v.pastTrip, true);
  assert.equal(v.pastLabel, 'Record a past trip');
  assert.equal(overrideView({ ...base, admin: false, past_trip: true }).pastLabel, 'Ask to record a past trip');
  const q = { id: 'q', action: 'past_trip' as const, status: 'requested', reason: 'Never recorded', requested_at: '', requested_by: null, mine: false, checks: null };
  assert.equal(overrideView({ ...base, past_trip: true, requests: [q] }).pastTrip, false);
});

test('Book it now waiting on an offered booking shows for an Admin to approve', () => {
  const q = { id: 'q', action: 'book_now' as const, status: 'requested', reason: 'Renter agreed by phone', requested_at: '', requested_by: 'Cy Service', mine: false, checks: [{ code: 'renter_approval', label: 'The renter has not approved the offer' }] };
  const v = overrideView({ ...base, status: 'offered', kind: null, requests: [q] });
  assert.equal(v.show && v.requests.length === 1 && !v.blocked, true);
  assert.match(requestLine(q), /booking the offer now/);
});
