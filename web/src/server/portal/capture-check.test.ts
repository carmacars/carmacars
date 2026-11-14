// r47: a capture clash is re-checked before a capture_failed To do.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { IDEMPOTENCY_CLASH, recheckCapture, recheckDelays } from './capture-check.ts';

const CLASH = 'There is currently another in-progress request using this Idempotent Key (that probably means you submitted twice, and the other request is still going through): capture:pi_x.';
const noSleep = async () => undefined;

test('the clash is known; a refusal is not', () => {
  assert.ok(IDEMPOTENCY_CLASH.test(CLASH));
  assert.ok(!IDEMPOTENCY_CLASH.test('Your card was declined.'));
  assert.equal(recheckDelays(CLASH).length, 4);
  assert.deepEqual(recheckDelays('Your card was declined.'), [0]);
});
test('a clash whose other request captured: no failure', async () => {
  const seq = ['requires_capture', 'requires_capture', 'succeeded'];
  let n = 0;
  assert.equal(await recheckCapture(CLASH, async () => ({ status: seq[n++] ?? 'succeeded' }), noSleep), 'captured');
  assert.equal(n, 3);
});
test('a refusal, a cancelled intent, or still not captured after the waits: a failure', async () => {
  assert.equal(await recheckCapture('Your card was declined.', async () => ({ status: 'requires_capture' }), noSleep), 'failed');
  assert.equal(await recheckCapture(CLASH, async () => ({ status: 'canceled' }), noSleep), 'failed');
  assert.equal(await recheckCapture(CLASH, async () => ({ status: 'requires_capture' }), noSleep), 'failed');
  assert.equal(await recheckCapture(CLASH, async () => { throw new Error('network'); }, noSleep), 'failed');
});
