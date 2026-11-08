import { test } from 'node:test';
import assert from 'node:assert/strict';
import { summaryLines } from './summary.ts';

test('summaryLines: only what happened', () => {
  assert.deepEqual(summaryLines({ imported: 12, skipped: 3, failed: 0, pending: 0 }), ['12 imported', '3 skipped']);
  assert.deepEqual(summaryLines({ imported: 0, failed: 2, pending: 5 }), ['2 failed', '5 to do']);
  assert.deepEqual(summaryLines(null), []);
  assert.deepEqual(summaryLines({}), []);
});
