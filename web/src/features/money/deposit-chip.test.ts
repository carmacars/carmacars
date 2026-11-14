import { test } from 'node:test';
import assert from 'node:assert/strict';
import { depositChip } from './deposit-words.ts';

test('the deposit chip says plainly whether a hold is on the card (Release 47)', () => {
  assert.deepEqual(depositChip('confirmed', 50000, { status: 'held', method: 'card_hold', amount_cents: 50000 }), { tone: 'succeeded', text: 'Deposit held $500 on the card' });
  assert.deepEqual(depositChip('on_rent', 30000, { status: 'captured', method: 'charged', amount_cents: 30000 }), { tone: 'succeeded', text: 'Deposit collected $300 charged to the card' });
  assert.deepEqual(depositChip('confirmed', 50000, null), { tone: 'pending_approval', text: 'No deposit hold yet' });
  assert.deepEqual(depositChip('confirmed', 50000, { status: 'failed', method: 'card_hold' }), { tone: 'failed', text: 'Deposit hold failed: declined or lapsed' });
  assert.deepEqual(depositChip('confirmed', 50000, null, true), { tone: 'done', text: 'Deposit waived' });
  assert.equal(depositChip('requested', 50000, null), null);
  assert.equal(depositChip('confirmed', 0, null), null);
});
