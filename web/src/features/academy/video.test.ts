import { test } from 'node:test';
import assert from 'node:assert/strict';
import { itemAlpha, sceneAt, timeline } from './video.ts';
import type { Scene } from './model.ts';

const sc = (n: number): Scene => ({ caption: 'c', say: Array.from({ length: n }, () => 'word').join(' '), visual: { kind: 'title', heading: 'h' } });

test('the video lasts as long as the player shows the scenes (captions-only timing)', () => {
  const tl = timeline([sc(1), sc(26)]);
  assert.deepEqual(tl.durations, [3, 11.2]);
  assert.deepEqual(tl.starts, [0, 3]);
  assert.equal(tl.total, 14.2);
});

test('the scene at a time', () => {
  const tl = timeline([sc(1), sc(26)]);
  assert.deepEqual(sceneAt(tl, 0), { index: 0, into: 0 });
  assert.deepEqual(sceneAt(tl, 4), { index: 1, into: 1 });
  assert.equal(sceneAt(tl, 99).index, 1);
  assert.deepEqual(sceneAt({ starts: [], durations: [] }, 1), { index: 0, into: 0 });
});

test('items arrive one by one', () => {
  assert.equal(itemAlpha(0, 0), 0);
  assert.equal(itemAlpha(0, 1), 1);
  assert.ok(itemAlpha(2, 0.9) === 0 && itemAlpha(2, 1.5) === 1);
});
