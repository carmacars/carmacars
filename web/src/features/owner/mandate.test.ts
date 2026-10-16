import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mandateText, payeeRows } from './mandate.ts';
import type { DebitTerms } from './types.ts';

// The owner's pre-authorized debit agreement (0037, 0051): every value comes from Program settings, the Late Fee is the
// one rule of the Enrollment Agreement (4.4), and the payee's contact details are shown with it.
const rule = 'If your bank returns the automatic debit of an invoice, we add the $50.00 Late Fee to that invoice once and try again from the 23rd, as section 4.4 of your Enrollment Agreement sets out.';
const terms: DebitTerms = {
  debit_day: 20, retry_day: 23, notice_days: 12, max_attempts: 2, retry_gap_days: 3, late_fee_cents: 5000, late_fee: '$50.00',
  debit_day_text: '20th', retry_day_text: '23rd', payout_day_text: '12th', interval_description: 'x', late_fee_rule: rule,
  own_debit_rule: 'A debit you start yourself from an invoice page that your bank returns adds no Late Fee: the invoice stays due and you can pay it again from its page.',
  payee: { name: 'CarmaCars', address: '100 Sample Street, Toronto, Ontario', phone: '647-555-0100', email: 'billing@carmacars.ca' }
};

test('the agreement reads the settings: debit day, notice days, the Late Fee rule; nothing typed', () => {
  const text = mandateText('personal', terms, false).join('\n');
  assert.match(text, /on the 20th of each month/);
  assert.match(text, /the total 12 days before each debit/);
  assert.ok(text.includes(rule));
  assert.doesNotMatch(text, /\b(15th|18th)\b/);
  assert.doesNotMatch(text, /unpaid after its due date/);
});

test('paying an invoice now: the same rule, and what a returned debit the owner started does', () => {
  const now = mandateText('business', terms, true);
  assert.match(now[0]!, /for this invoice now, and for the fees/);
  assert.equal(now[1], `${rule} ${terms.own_debit_rule}`);
  assert.match(now.join('\n'), /for business purposes/);
  assert.doesNotMatch(mandateText('personal', terms, false).join('\n'), /start yourself/);
});

test('the payee: the business name, address, phone and the email that takes a cancellation; never the numbered company by default', () => {
  assert.deepEqual(payeeRows(terms), [['Payee', 'CarmaCars'], ['Address', '100 Sample Street, Toronto, Ontario'], ['Phone', '647-555-0100'], ['Email', 'billing@carmacars.ca']]);
  assert.match(mandateText('personal', terms, false)[0]!, /^You authorize CarmaCars to debit/);
  assert.match(mandateText('personal', terms, false)[3]!, /by writing to billing@carmacars\.ca/);
  const legal = { ...terms, payee: { ...terms.payee, name: 'Example Holdings Inc., operating as CarmaCars', address: '' } };
  assert.match(mandateText('personal', legal, false)[0]!, /^You authorize Example Holdings Inc\., operating as CarmaCars, to debit/);
  assert.equal(payeeRows(legal)[1]![1], 'Not set yet');
});
