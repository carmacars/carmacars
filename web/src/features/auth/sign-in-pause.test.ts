import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SIGN_IN_PAUSED, signInPaused } from './sign-in-pause.ts';

test('paused only on a plain false from the database', () => {
  assert.equal(signInPaused(false), true);
  for (const a of [true, null, undefined, 'false', 0, {}, []]) assert.equal(signInPaused(a), false);
});

test('the message does not say whether the account exists', () => {
  assert.doesNotMatch(SIGN_IN_PAUSED, /no account|not found|does not exist|your account/i);
});
