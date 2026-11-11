import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compact, growth, trendBars } from './search.ts';

test('deck search words: compact numbers, growth, trend bars', () => {
  assert.equal(compact(172000), '172K');
  assert.equal(compact(1500), '1.5K');
  assert.equal(compact(2_400_000), '2.4M');
  assert.equal(compact(null), 'n/a');
  assert.equal(growth(100), '+100% on the 28 days before');
  assert.equal(growth(null), 'new');
  assert.deepEqual(trendBars([{ week_of: 'a', clicks: 1, impressions: 50 }, { week_of: 'b', clicks: 2, impressions: 100 }]), [50, 100]);
});
