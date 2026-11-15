import { test } from 'node:test';
import assert from 'node:assert/strict';
import { depositChip, depositPendingLine } from './deposit-words.ts';

test('the deposit chip says plainly whether a hold is on the card (Release 47)', () => {
  assert.deepEqual(depositChip('confirmed', 50000, { status: 'held', method: 'card_hold', amount_cents: 50000 }), { tone: 'succeeded', text: 'Deposit held $500 on the card' });
  assert.deepEqual(depositChip('on_rent', 30000, { status: 'captured', method: 'charged', amount_cents: 30000 }), { tone: 'succeeded', text: 'Deposit collected $300 charged to the card' });
  assert.deepEqual(depositChip('confirmed', 50000, null), { tone: 'pending_approval', text: 'No deposit hold yet' });
  assert.deepEqual(depositChip('confirmed', 50000, { status: 'failed', method: 'card_hold' }), { tone: 'failed', text: 'Deposit hold failed: declined or lapsed' });
  assert.deepEqual(depositChip('confirmed', 50000, null, true), { tone: 'done', text: 'Deposit waived' });
  assert.equal(depositChip('requested', 50000, null), null);
  assert.equal(depositChip('confirmed', 0, null), null);
});

test('r48: a car out with the deposit owed shows "Deposit pending $X"; red after 48 hours; gone once held', () => {
  assert.deepEqual(depositChip('on_rent', 50000, null, false, { pending: true, amount_cents: 50000 }), { tone: 'pending_approval', text: 'Deposit pending $500' });
  assert.deepEqual(depositChip('on_rent', 50000, null, false, { pending: true, amount_cents: 45050, overdue: true }), { tone: 'failed', text: 'Deposit pending $450.50' });
  assert.deepEqual(depositChip('on_rent', 50000, { status: 'held', method: 'card_hold', amount_cents: 50000 }, false, { pending: true, amount_cents: 50000 }), { tone: 'succeeded', text: 'Deposit held $500 on the card' });
  assert.deepEqual(depositChip('on_rent', 50000, null, false, { pending: false }), { tone: 'pending_approval', text: 'No deposit hold yet' });
});

test('r48: the line under the chip says why and what the morning job did', () => {
  assert.equal(depositPendingLine(null), null);
  assert.equal(depositPendingLine({ pending: true, by_name: 'Fleet Person', reason: 'Card declined at the lot' }),
    'The car went out with the deposit owed by Fleet Person: Card declined at the lot. Each morning the saved card is tried once, then the deposit link goes to the renter.');
  assert.equal(depositPendingLine({ pending: true, last_try_on: '2026-11-15', last_try_result: 'Your card was declined.', last_link_on: '2026-11-15', overdue: true }),
    'The car went out with the deposit owed. Last morning try 2026-11-15 (Your card was declined.), link sent 2026-11-15. Still owed after 48 hours: take it on the Money tab.');
  assert.match(depositPendingLine({ pending: true, retry_on: false })!, /morning retry is off/);
});
