import { test } from 'node:test';
import assert from 'node:assert/strict';
import { waitWords } from './wait-words.ts';

test('one humane wait format', () => {
  assert.equal(waitWords(0), 'under a minute');
  assert.equal(waitWords(12), '12 min');
  assert.equal(waitWords(200), '3 h');
  assert.equal(waitWords(1500), '1 day');
  assert.equal(waitWords(27294), '18 days');
});
