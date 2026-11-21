import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LiveTokens, revocationKeys } from './revoke.ts';

test('a token is revoked by its hash and by its sign-in session, never stored itself', async () => {
  const k = await revocationKeys('abc.def.ghi', { session_id: '0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9' });
  assert.equal(k.length, 2);
  assert.match(k[0]!, /^t:[0-9a-f]{64}$/);
  assert.equal(k[1], 's:0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9');
  assert.ok(!k.join().includes('abc.def.ghi'));
  assert.notEqual((await revocationKeys('abc.def.ghj', null))[0], k[0], 'another token, another hash');
});

test('a session id that is not one is left out', async () => {
  assert.equal((await revocationKeys('t', { session_id: "x' or 1=1" })).length, 1);
  assert.equal((await revocationKeys('t', { session_id: 42 })).length, 1);
});

test('a live token is remembered a few seconds only, and dropped at once on sign-out', () => {
  const live = new LiveTokens(1000, 3);
  live.add('a', 0);
  assert.equal(live.has('a', 999), true);
  assert.equal(live.has('a', 1000), false, 'then asked again');
  live.add('b', 0);
  live.drop('b');
  assert.equal(live.has('b', 1), false);
  live.add('c', 0); live.add('d', 0); live.add('e', 0); live.add('f', 0);
  assert.equal(live.has('c', 1), false, 'bounded: a full table starts over');
});
