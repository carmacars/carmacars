import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isExtra, moveItem } from './extra-order.ts';

test('moveItem: moves one item, held inside the list; the list given is not changed', () => {
  const l = ['a', 'b', 'c', 'd'];
  assert.deepEqual(moveItem(l, 3, 0), ['d', 'a', 'b', 'c']);
  assert.deepEqual(moveItem(l, 0, 2), ['b', 'c', 'a', 'd']);
  assert.deepEqual(moveItem(l, 1, 99), ['a', 'c', 'd', 'b']);
  assert.deepEqual(moveItem(l, 1, -5), ['b', 'a', 'c', 'd']);
  assert.deepEqual(moveItem(l, 9, 0), l);
  assert.deepEqual(l, ['a', 'b', 'c', 'd']);
  assert.equal(isExtra('exterior_more'), true);
  assert.equal(isExtra('front_left'), false);
});
