import { test } from 'node:test';
import assert from 'node:assert/strict';
import { payCardStep } from './pay-card.ts';

test('payCardStep: a charge is captured only after the card is accepted; a refused card is never charged', () => {
  assert.equal(payCardStep('charge', 'requires_capture', true), 'capture');
  assert.equal(payCardStep('charge', 'requires_capture', false), 'refuse');
  assert.equal(payCardStep('charge', 'succeeded', false), 'refuse');
  assert.equal(payCardStep('charge', 'succeeded', true), 'settle');
  assert.equal(payCardStep('charge', 'requires_payment_method', false), 'settle');
});
test('payCardStep: a hold with a debit or prepaid card is voided; saving a card is not concerned', () => {
  assert.equal(payCardStep('hold', 'requires_capture', false), 'refuse');
  assert.equal(payCardStep('hold', 'requires_capture', true), 'settle');
  assert.equal(payCardStep('setup', 'succeeded', false), 'settle');
});
