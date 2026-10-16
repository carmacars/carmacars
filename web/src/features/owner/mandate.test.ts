import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mandateText, oneTimeText, payeeRows } from './mandate.ts';
import type { DebitTerms } from './types.ts';

// The owner's pre-authorized debit texts (the legal review, 0053): the payee is "<legal name>, operating as CarmaCars",
// the recurring agreement is the database's text word for word, the one-time box is the approved sentence.
const rule = 'If your bank returns the automatic debit of an invoice for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.';
const payee = { name: '18122211 Canada Inc., operating as CarmaCars', address: '2967 Dundas St W, Unit 208B, Toronto, ON', phone: '647-555-0100', email: 'billing@carmacars.ca' };
const terms: DebitTerms = {
  debit_day: 20, retry_day: 23, notice_days: 12, max_attempts: 2, retry_gap_days: 3, late_fee_cents: 5000, late_fee: '$50.00',
  debit_day_text: '20th', retry_day_text: '23rd', payout_day_text: '12th', interval_description: 'x', late_fee_rule: rule,
  own_debit_rule: 'A debit you start yourself from an invoice page that your bank returns adds no Late Fee: the invoice stays due and you can pay it again from its page.',
  payee
};

test('without the database text: the recurring agreement reads the settings, the payee and the new Late Fee rule', () => {
  const text = mandateText('personal', terms).join('\n');
  assert.match(text, /^You authorize 18122211 Canada Inc\., operating as CarmaCars, to debit the bank account you give for the fees/);
  assert.match(text, /on the 20th of each month/);
  assert.match(text, /the total 12 days before each debit/);
  assert.ok(text.includes(rule));
  assert.match(text, /for personal purposes/);
  assert.doesNotMatch(text, /\b(15th|18th)\b/);
  assert.doesNotMatch(text, /for this invoice now/);
});

test('the database text wins, word for word', () => {
  const agreement = { personal: ['p1', 'p2', 'p3', 'p4'], business: ['b1', 'b2', 'b3', 'b4'] };
  assert.deepEqual(mandateText('business', { ...terms, agreement }), ['b1', 'b2', 'b3', 'b4']);
});

test('the one-time box: the approved sentence with the payee, amount and invoice', () => {
  assert.equal(oneTimeText(terms, '$536.75', 'INV-1042'),
    'I authorize 18122211 Canada Inc., operating as CarmaCars, to debit $536.75 for invoice INV-1042 from the bank account I give now. I waive pre-notification and any waiting period for this one-time debit.');
});

test('the payee rows: the legal name operating as CarmaCars, address, phone and the email that takes a cancellation', () => {
  assert.deepEqual(payeeRows(terms), [['Payee', payee.name], ['Address', payee.address], ['Phone', payee.phone], ['Email', 'billing@carmacars.ca']]);
  assert.equal(payeeRows({ ...terms, payee: { ...payee, address: '' } })[1]![1], 'Not set yet');
});
