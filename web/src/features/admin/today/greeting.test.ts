import { test } from 'node:test';
import assert from 'node:assert/strict';
import { greetName } from './greeting.ts';

test('the greeting name whole when set; else the first word of the account name', () => {
  assert.equal(greetName({ name: 'CarmaCars Admin', greeting: 'Abbas and Mahad' }), 'Abbas and Mahad');
  assert.equal(greetName({ name: 'CarmaCars Admin', greeting: 'CarmaCars Admin' }), 'CarmaCars', 'no greeting name: the database gives the account name');
  assert.equal(greetName({ name: 'Ada Admin' }), 'Ada');
  assert.equal(greetName({ name: null, greeting: null }), null);
});
