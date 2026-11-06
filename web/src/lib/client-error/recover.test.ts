import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recoveryFor } from './recover.ts';

const now = 1_800_000_000_000;
test('a page of an older deploy or a failed server render reloads once a minute at most', () => {
  for (const message of ['Failed to find Server Action "7f3a". This request might be from an older or newer deployment.', 'ChunkLoadError: Loading chunk 812 failed.',
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
