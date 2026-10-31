import { test } from 'node:test';
import assert from 'node:assert/strict';
import { autoHoldStep } from './deposit-auto.ts';

test('an authorized hold is recorded', () => {
  assert.deepEqual(autoHoldStep({ status: 'requires_capture' }), { next: 'settle' });
  assert.deepEqual(autoHoldStep({ status: 'succeeded' }), { next: 'settle' });
});

test('a decline is a failure with the bank\'s reason; nothing to cancel', () => {
  assert.deepEqual(autoHoldStep({ status: 'requires_payment_method', lastError: 'Your card was declined.' }), { next: 'failed', reason: 'Your card was declined.', cancel: false });
});

test('the bank wants the renter: failed, and the waiting authorization is cancelled', () => {
  assert.deepEqual(autoHoldStep({ status: 'requires_action' }), { next: 'failed', reason: 'the bank wants the renter to approve the hold', cancel: true });
});

test('Stripe threw: authentication required or the message', () => {
  assert.equal((autoHoldStep(null, Object.assign(new Error('This payment requires authentication'), { code: 'authentication_required' })) as { reason: string }).reason, 'the bank wants the renter to approve the hold');
  assert.equal((autoHoldStep(null, new Error('Your card has insufficient funds.')) as { reason: string }).reason, 'Your card has insufficient funds.');
  assert.equal((autoHoldStep(null, null) as { reason: string }).reason, 'Stripe could not be reached');
});
