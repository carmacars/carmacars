import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ownerUseStateWords } from './owner-use.ts';

const day = (d: string) => d;
const base = { status: 'issued', balance_cents: 5000, deduct_after: '2026-12-07', reminders: 0 };
test('owner-use charges: where an invoice stands, in words', () => {
  assert.equal(ownerUseStateWords({ ...base, state: 'card' }, day).word, 'Charging the card');
  assert.equal(ownerUseStateWords({ ...base, state: 'debit' }, day).word, 'Bank debit');
  const p = ownerUseStateWords({ ...base, state: 'pay_now', reminders: 2 }, day);
  assert.equal(p.warn, true);
  assert.match(p.text, /2 reminders sent/);
  assert.match(p.text, /not paid by 2026-12-07, it is deducted from the next statement/);
  assert.match(ownerUseStateWords({ ...base, state: 'pay_now', reminders: 1 }, day).text, /1 reminder sent\)/);
  assert.equal(ownerUseStateWords({ ...base, state: 'deducting' }, day).word, 'From the statement');
  assert.equal(ownerUseStateWords({ ...base, state: 'deducting', status: 'paid', balance_cents: 0 }, day).word, 'Paid');
  assert.match(ownerUseStateWords({ ...base, state: null, deduct_after: null }, day).text, /by the next statement cut-off/);
});
