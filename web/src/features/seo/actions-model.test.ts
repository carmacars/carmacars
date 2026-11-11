import test from 'node:test';
import assert from 'node:assert/strict';
import { ctrText, goalShare, indexedShare, num, positionText } from './actions-model.ts';

test('SEO page figures: the goal share, click rate, position and indexed share', () => {
  assert.equal(goalShare(100), '1%');
  assert.equal(goalShare(42), '0.4%');
  assert.equal(goalShare(4200), '42%');
  assert.equal(ctrText({ key: '/x', clicks: 5, impressions: 1000, ctr: 0.005, position: 8 }), '0.5%');
  assert.equal(ctrText({ key: '/x', clicks: 5, impressions: 1000, ctr: null, position: null }), '0.5%');
  assert.equal(positionText(7.86), '7.9');
  assert.equal(num(5000000), '5,000,000');
  assert.equal(indexedShare({ indexed: 62, crawled: 30, discovered: 8 }), 0.62);
  assert.equal(indexedShare({ indexed: 0, crawled: 0, discovered: 0 }), null);
});
