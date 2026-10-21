import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardCoverageHint, cardCoverageMessage, cardCoverageProblem, cardLabel, sameName, type CardFacts } from './card.ts';

// Credit card rental coverage (Coverage Option 2): only a credit card, never debit or prepaid, in the renter's name.
const card = (o: Partial<CardFacts> = {}): CardFacts => ({ brand: 'visa', last4: '4242', funding: 'credit', cardholder_name: 'Morgan Payer', country: 'CA', ...o });

test('funding check: a credit card in the renter\'s name qualifies', () => {
  assert.equal(cardCoverageProblem(card(), 'Morgan Payer'), null);
  assert.equal(cardCoverageMessage(null, card()), null);
});

test('funding check: debit, prepaid and unknown funding are refused, with the option to choose OPCF 27 or the Protection Plan', () => {
  for (const f of ['debit', 'prepaid', 'unknown'] as const) assert.equal(cardCoverageProblem(card({ funding: f }), 'Morgan Payer'), 'not_credit', f);
  assert.equal(cardCoverageProblem(card({ funding: null }), 'Morgan Payer'), 'not_credit');
  const m = cardCoverageMessage('not_credit', card({ funding: 'debit', last4: '5556' }))!;
  assert.match(m, /Visa ending 5556\) is a debit card/);
  assert.match(m, /OPCF 27/);
  assert.match(m, /Protection Plan/);
  assert.match(cardCoverageMessage('not_credit', card({ funding: 'prepaid' }))!, /a prepaid card/);
  assert.doesNotMatch(m, /insurance|—/i);
});

test('funding check: no card yet, and a card in someone else\'s name', () => {
  assert.equal(cardCoverageProblem(null, 'Morgan Payer'), 'no_card');
  assert.equal(cardCoverageProblem(card({ last4: null }), 'Morgan Payer'), 'no_card');
  assert.equal(cardCoverageProblem(card({ cardholder_name: 'Someone Else' }), 'Morgan Payer'), 'name_mismatch');
  assert.equal(cardCoverageProblem(card({ cardholder_name: null }), 'Morgan Payer'), 'name_mismatch');
  assert.match(cardCoverageMessage('name_mismatch', card())!, /not in your name/);
});

test('names match as the database matches them: case, spaces and punctuation ignored', () => {
  assert.equal(sameName('MORGAN  PAYER', 'morgan payer'), true);
  assert.equal(sameName('Anne-Marie O\'Neil', 'Anne Marie ONeil'), true);
  assert.equal(sameName('Zoë Tremblay', 'Zoe Tremblay'), true);
  assert.equal(sameName('', ''), false);
  assert.equal(sameName('Morgan Payer', 'Morgan Payne'), false);
});

test('the staff hint per card type comes from the brand and funding only', () => {
  assert.match(cardCoverageHint(card({ brand: 'amex' }))!, /^Coverage known for this card type: most American Express/);
  assert.match(cardCoverageHint(card({ brand: 'visa' }))!, /Infinite, Avion/);
  assert.match(cardCoverageHint(card({ brand: 'mastercard' }))!, /World Elite/);
  assert.match(cardCoverageHint(card({ brand: 'discover' }))!, /uncommon/);
  assert.match(cardCoverageHint(card({ funding: 'debit' }))!, /not available on this card/);
  assert.match(cardCoverageHint(card({ country: 'US' }))!, /outside Canada \(US\)/);
  assert.equal(cardCoverageHint(card({ brand: 'link' })), null);
  assert.equal(cardCoverageHint(null), null);
  assert.equal(cardLabel({ brand: 'amex', last4: '0005' }), 'American Express ending 0005');
});
