import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LOCAL_LINK_KEY, pickLinkSecret } from './link-secret.ts';

test('the configured key always wins', () => {
  for (const APP_ENV of ['local', 'staging', 'production']) assert.equal(pickLinkSecret({ LINK_SIGNING_KEY: 'k'.repeat(32), LOCAL_AUTH_SECRET: 'other', APP_ENV }), 'k'.repeat(32));
});

test('the fixed local key signs only on a local run', () => {
  assert.equal(pickLinkSecret({ APP_ENV: 'local' }), LOCAL_LINK_KEY);
  assert.equal(pickLinkSecret({}), LOCAL_LINK_KEY);
  assert.equal(pickLinkSecret({ APP_ENV: 'staging' }), undefined);
  assert.equal(pickLinkSecret({ APP_ENV: 'production' }), undefined);
});

test('staging may fall back to its own secret, production never', () => {
  assert.equal(pickLinkSecret({ APP_ENV: 'staging', LOCAL_AUTH_SECRET: 's'.repeat(32) }), 's'.repeat(32));
  assert.equal(pickLinkSecret({ APP_ENV: 'production', LOCAL_AUTH_SECRET: 's'.repeat(32) }), undefined);
});
