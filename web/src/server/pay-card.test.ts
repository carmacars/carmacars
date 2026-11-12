import { test } from 'node:test';
import assert from 'node:assert/strict';
import { extendedRefusedText, holdAmountMessage, holdAmountStep, payCardStep } from './pay-card.ts';

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
test('holdAmountStep: a debit card on a credit-card hold is asked again for the debit deposit; the right amount settles', () => {
  assert.deepEqual(holdAmountStep(30000, 60000), { reask: true, amountCents: 60000 });
  assert.deepEqual(holdAmountStep(60000, 30000), { reask: true, amountCents: 30000 });
  assert.deepEqual(holdAmountStep(60000, 60000), { reask: false });
  assert.deepEqual(holdAmountStep(30000, null), { reask: false });
  assert.match(holdAmountMessage('debit', 60000), /debit or prepaid card the deposit hold is \$600\.00/);
  assert.match(holdAmountMessage('credit', 30000), /credit card the deposit hold is \$300\.00/);
});
test('extendedRefusedText: only the refusal of the longer hold asks again as a standard hold, never an ordinary decline', () => {
  assert.equal(extendedRefusedText('This account is not eligible for the requested card features.'), true);
  assert.equal(extendedRefusedText('Extended authorization is not available for this card.'), true);
  assert.equal(extendedRefusedText('Your card was declined.'), false);
  assert.equal(extendedRefusedText('Your card has insufficient funds.'), false);
  assert.equal(extendedRefusedText(null), false);
});
