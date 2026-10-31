import { test } from 'node:test';
import assert from 'node:assert/strict';
import { depositAutoText } from './deposit-auto-text.ts';

const when = (s: string) => `at ${s}`;
const money = (c: number) => `$${(c / 100).toFixed(2)}`;

test('off or nothing: no line', () => {
  assert.equal(depositAutoText(null, when, money), null);
  assert.equal(depositAutoText({ status: 'off' }, when, money), null);
});
test('scheduled, held and failed say where the hold is', () => {
  assert.equal(depositAutoText({ status: 'scheduled', due_at: 'X', amount_cents: 50000 }, when, money), 'Deposit hold of $500.00 placed automatically on the card on file at X.');
  assert.match(depositAutoText({ status: 'held', at: 'Y', amount_cents: 50000 }, when, money)!, /placed automatically on the card on file at Y/);
  assert.match(depositAutoText({ status: 'failed', error: 'Your card was declined.' }, when, money)!, /^Deposit not taken: .*Your card was declined\..*take it now/);
  assert.match(depositAutoText({ status: 'no_card' }, when, money)!, /No usable card on file/);
});
