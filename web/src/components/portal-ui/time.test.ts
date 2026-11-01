import { test } from 'node:test';
import assert from 'node:assert/strict';
import { waitWords } from './time.ts';

test('waits in one humane format (0324): "6 days", "1 day", "3 h", "12 min"', () => {
  assert.equal(waitWords(9672), '6 days');
  assert.equal(waitWords(1500), '1 day');
  assert.equal(waitWords(185), '3 h');
  assert.equal(waitWords(12.7), '12 min');
  assert.equal(waitWords(0), '1 min');
});
