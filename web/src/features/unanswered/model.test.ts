import { test } from 'node:test';
import assert from 'node:assert/strict';
import { waitWords } from './model.ts';

test('1061: waiting time in words', () => {
  assert.equal(waitWords(14), '14 min');
  assert.equal(waitWords(75), '1 h 15 min');
  assert.equal(waitWords(1500), '1 d 1 h');
});
