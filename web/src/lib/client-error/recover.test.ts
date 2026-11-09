import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recoveryFor } from './recover.ts';

const now = 1_800_000_000_000;
test('a page of an older deploy or a failed server render reloads once a minute at most', () => {
  for (const message of ['Failed to load chunk /_next/static/chunks/0abc.js from module 369363', 'Failed to find Server Action "7f3a". This request might be from an older or newer deployment.', 'ChunkLoadError: Loading chunk 812 failed.',
    'Minified React error #441; visit https://react.dev/errors/441 for the full message', 'An unexpected response was received from the server.', 'Failed to fetch']) {
    assert.equal(recoveryFor({ message }, 0, now), 'reload', message);
    assert.equal(recoveryFor({ message }, now - 30_000, now), 'none', `${message}: not twice a minute`);
    assert.equal(recoveryFor({ message }, now - 61_000, now), 'reload');
  }
});
test('a bug in the page is shown, not reloaded', () => {
  assert.equal(recoveryFor({ message: "Cannot read properties of undefined (reading 'map')" }, 0, now), 'none');
  assert.equal(recoveryFor(null, 0, now), 'none');
});

import { causeOf, dialable, readContact, retryDelayS } from './recover.ts';
test('r27b: the page says whose problem it is, retries with backoff and shows the contact', () => {
  assert.equal(causeOf({ message: 'Minified React error #441; visit https://react.dev/errors/441' }), 'server');
  assert.equal(causeOf({ message: 'error code: 504' }), 'server');
  assert.equal(causeOf({ message: 'Failed to fetch' }), 'server');
  assert.equal(causeOf({ message: 'Failed to find Server Action "x". This request might be from an older or newer deployment.' }), 'stale');
  assert.equal(causeOf({ message: "Cannot read properties of undefined (reading 'map')" }), 'device');
  assert.deepEqual([0, 1, 2, 3, 4, 9].map(retryDelayS), [5, 10, 20, 40, 60, 60]);
  assert.deepEqual(readContact(null), { phone: '289-312-5991', email: 'contact@carmacars.ca' });
  const doc = { querySelector: () => ({ getAttribute: () => JSON.stringify({ phone: '416-555-0100', email: 'hello@example.test' }) }) };
  assert.deepEqual(readContact(doc), { phone: '416-555-0100', email: 'hello@example.test' });
  assert.equal(dialable('289-312-5991'), '+12893125991');
});
