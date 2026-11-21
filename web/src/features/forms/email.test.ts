import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalEmail, plainEmail } from './email.ts';

test('one form of an address: NFKC, trimmed, lower case', () => {
  assert.equal(normalEmail('  Bob@Example.TEST '), 'bob@example.test');
  assert.equal(normalEmail('ｂｏｂ@example.test'), 'bob@example.test', 'full-width letters');
  assert.equal(normalEmail('bob@exa\u212Aple.test'), 'bob@exakple.test', 'the Kelvin sign is a K');
});

test('a new account takes printable ASCII only, so a look-alike address is refused', () => {
  assert.equal(plainEmail('bob@example.test'), true);
  assert.equal(plainEmail('bоb@example.test'), false, 'a Cyrillic o');
  assert.equal(plainEmail(normalEmail('Бob@example.test')), false);
  assert.equal(plainEmail('bob @example.test'), false);
});
