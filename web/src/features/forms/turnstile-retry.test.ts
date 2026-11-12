// Turnstile errors: retry or give up (r40).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { turnstileRetry } from './turnstile-retry.ts';

test('turnstileRetry: network and timeout errors retry up to 3 times, setup errors never', () => {
  assert.equal(turnstileRetry('300030', 0), true);
  assert.equal(turnstileRetry('600010', 2), true);
  assert.equal(turnstileRetry('600010', 3), false);
  assert.equal(turnstileRetry(undefined, 0), true);
  assert.equal(turnstileRetry('110200', 0), false);
  assert.equal(turnstileRetry(400020, 0), false);
});
