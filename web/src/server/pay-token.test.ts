import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { isPayToken, newPayToken, payTokenHash } from './pay-token.ts';

test('a pay token is URL-safe, 43 characters, different every time', () => {
  const a = newPayToken(); const b = newPayToken();
  assert.match(a, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(a, b);
  assert.ok(isPayToken(a));
});

test('the hash the database keeps is the SHA-256 of the token, as the database computes it', async () => {
  const t = newPayToken();
  assert.equal(await payTokenHash(t), createHash('sha256').update(t, 'utf8').digest('hex'));
});

test('the pay page refuses anything that is not a token', () => {
  for (const x of ['', 'short', 'has space in it aaaaaaaaaaaaaaaaaaa', '../../etc/passwd/aaaaaaaaaaaaaa', 'a'.repeat(65)]) assert.equal(isPayToken(x), false, x);
});
