import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NO_WORDS, refusalMessage } from './refusal.ts';

test('a database refusal is shown as written', () => { assert.equal(refusalMessage(new Error('ERROR: The car is not free')), 'The car is not free'); });
test('an error without words still says something', () => {
  assert.equal(refusalMessage(new Error('')), NO_WORDS);
  assert.equal(refusalMessage(null), NO_WORDS);
  assert.equal(refusalMessage(new Error('ERROR:   ')), NO_WORDS);
});
