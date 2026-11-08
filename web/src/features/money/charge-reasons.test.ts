import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CHARGE_REASONS, holdExpired, isLapsedError, plainProcessorError, reasonText } from './charge-reasons.ts';

test('the reason list, in the owner\'s order, Other last', () => {
  assert.deepEqual(CHARGE_REASONS.map(([, l]) => l), ['Mileage overage', 'Fuel', 'Cleaning', 'Smoking', 'Late return', 'Tolls', 'Tickets/fines', 'Damage', 'Missing items', 'Other']);
  assert.equal(reasonText('fuel', ' a quarter tank '), 'Fuel: a quarter tank');
  assert.equal(reasonText('tolls', ''), 'Tolls');
  assert.equal(reasonText('other', ''), null);
  assert.equal(reasonText('other', 'Lost key fob'), 'Other: Lost key fob');
  assert.equal(reasonText('vibes', 'x'), null);
});

test('the expired hold: Stripe\'s raw answer is never shown', () => {
  const raw = 'This PaymentIntent could not be captured because it has a status of canceled. Only a PaymentIntent with one of the following statuses may be captured: requires_capture.';
  assert.equal(isLapsedError(raw), true);
  assert.equal(plainProcessorError(raw, 'keep'), 'The card hold has expired, so nothing can be kept from it. Charge the card on file instead.');
  assert.doesNotMatch(plainProcessorError('Stripe answered requires_payment_method'), /Stripe|requires_/);
  assert.match(plainProcessorError('Your card has insufficient funds.'), /not enough funds/);
  assert.equal(plainProcessorError('The card was declined.'), 'The card was declined by the bank. Send the renter a pay link, or try again later.');
});

test('a hold past its expiry is expired; a held one is not', () => {
  const now = Date.parse('2026-11-07T12:00:00Z');
  assert.equal(holdExpired({ method: 'card_hold', status: 'held', hold_expires_at: '2026-11-07T11:00:00Z' }, now), true);
  assert.equal(holdExpired({ method: 'card_hold', status: 'held', hold_expires_at: '2026-11-08T11:00:00Z' }, now), false);
  assert.equal(holdExpired({ method: 'charged', status: 'captured', hold_expires_at: '2026-11-01T11:00:00Z' }, now), false);
});
