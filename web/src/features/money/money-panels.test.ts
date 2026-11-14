import { test } from 'node:test';
import assert from 'node:assert/strict';
import { depositNext, depositWord, failedAttemptState, isDeposit, paidTotals, rentalDue } from './money-panels.ts';

test('the deposit in one word', () => {
  assert.equal(depositWord(null, 50000), 'Not collected');
  assert.equal(depositWord(null, 0), 'No deposit');
  assert.equal(depositWord(null, 50000, true), 'Waived');
  assert.equal(depositWord({ method: 'card_hold', status: 'failed', amount_cents: 50000 }, 50000), 'Not collected');
  assert.equal(depositWord({ method: 'card_hold', status: 'held', amount_cents: 50000 }, 50000), 'Held');
  assert.equal(depositWord({ method: 'card_hold', status: 'held', amount_cents: 50000, hold_expires_at: '2020-01-01T00:00:00Z' }, 50000), 'Hold expired');
  assert.equal(depositNext('Hold expired', 'returned'), 'expired');
  assert.equal(depositWord({ method: 'charged', status: 'captured', amount_cents: 50000 }, 50000), 'Charged');
  assert.equal(depositWord({ method: 'offline', paid_method: 'cash', status: 'captured', amount_cents: 50000 }, 50000), 'Charged');
  assert.equal(depositWord({ method: 'card_hold', status: 'settled', amount_cents: 50000, released_cents: 50000 }, 50000), 'Released');
  assert.equal(depositWord({ method: 'card_hold', status: 'settled', amount_cents: 50000, released_cents: 30000, applied_cents: 20000 }, 50000), 'Partly kept');
});

test('the deposit\'s next step', () => {
  assert.equal(depositNext('Not collected', 'confirmed'), 'collect');
  assert.equal(depositNext('Not collected', 'cancelled'), 'none');
  assert.equal(depositNext('Held', 'on_rent'), 'held');
  assert.equal(depositNext('Held', 'returned'), 'settle');
  assert.equal(depositNext('Charged', 'returned'), 'settle');
  assert.equal(depositNext('Released', 'closed'), 'none');
});

test('rental and deposit money never mix', () => {
  const rows = [
    { purpose: 'booking_total', kind: 'charge', method: 'card', amount_cents: 60000, status: 'succeeded', covers: 'rental' },
    { purpose: 'booking_total', kind: 'charge', method: 'cash', amount_cents: 5000, status: 'succeeded', covers: 'fees' },
    { purpose: 'deposit', kind: 'charge', method: 'cash', amount_cents: 50000, status: 'succeeded', covers: 'deposit' },
    { purpose: 'deposit', kind: 'hold', method: 'card', amount_cents: 50000, status: 'succeeded', covers: 'deposit' },
    { purpose: 'booking_total', kind: 'refund', method: 'card', amount_cents: 10000, status: 'succeeded', covers: 'rental' },
    { purpose: 'booking_total', kind: 'charge', method: 'card', amount_cents: 99900, status: 'failed', covers: 'rental' },
    { purpose: 'booking_total', kind: 'charge', method: 'e_transfer', amount_cents: 7000, status: 'succeeded', covers: 'rental', voided: true }];
  assert.deepEqual(paidTotals(rows), { rental_cents: 55000, deposit_cents: 50000, total_cents: 105000 });
  assert.equal(isDeposit({ purpose: 'booking_total', covers: 'deposit' }), true);
  assert.deepEqual(rentalDue([{ covers: 'rental', open_cents: 30000 }, { covers: 'fees', open_cents: 2500 }, { covers: 'later', open_cents: 1000 }]), { due_cents: 32500, later_cents: 1000 });
});

test('r44: a deposit marked charged with no money received reads Not collected, never "Charged $1,000"', () => {
  assert.equal(depositWord({ method: 'offline', paid_method: 'cash', status: 'captured', amount_cents: 100000 }, 100000, false, Date.now(), 0), 'Not collected');
  assert.equal(depositWord({ method: 'charged', status: 'captured', amount_cents: 100000 }, 100000, false, Date.now(), 100000), 'Charged');
  // a card hold captured is read from the hold itself
  assert.equal(depositWord({ method: 'card_hold', status: 'captured', amount_cents: 100000 }, 100000, false, Date.now(), 0), 'Partly kept');
});

test('r44: a failed card attempt is "settled" only by a recorded payment that names it; else nothing owing, or open', () => {
  const parts = [{ covers: 'rental', open_cents: 0 }, { covers: 'fees', open_cents: 0 }, { covers: 'later', open_cents: 0 }];
  assert.equal(failedAttemptState({ id: 'p1', purpose: 'booking_total' }, [{ settles_payment_id: 'p1', voided_at: null }], parts), 'settled');
  assert.equal(failedAttemptState({ id: 'p1', purpose: 'booking_total' }, [{ settles_payment_id: 'p1', voided_at: '2026-11-01T00:00:00Z' }], parts), 'nothing_owing');
  assert.equal(failedAttemptState({ id: 'p1', purpose: 'booking_total' }, [], [{ covers: 'rental', open_cents: 1083 }]), 'open');
  assert.equal(failedAttemptState({ id: 'p1', purpose: 'deposit' }, [], parts), 'open');
});
