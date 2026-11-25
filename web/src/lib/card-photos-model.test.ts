// The car card's photo and drive-off rules (card-photos-model.ts).   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DRIVE_NAV_MS, parseBox, plainClick, rearPivot, segmentAt, slidePhotos, snapIndex, stepIndex } from './card-photos-model.ts';

test('the pointer picks photo 1..N by segment, clamped at the edges', () => {
  assert.equal(segmentAt(0, 300, 5), 0);
  assert.equal(segmentAt(59, 300, 5), 0);
  assert.equal(segmentAt(60, 300, 5), 1);
  assert.equal(segmentAt(299, 300, 5), 4);
  assert.equal(segmentAt(400, 300, 5), 4);
  assert.equal(segmentAt(-5, 300, 5), 0);
  assert.equal(segmentAt(100, 0, 5), 0);
  assert.equal(segmentAt(100, 300, 1), 0);
});

test('the track rests on the nearest photo; the arrow keys stop at the ends', () => {
  assert.equal(snapIndex(0, 375, 5), 0);
  assert.equal(snapIndex(200, 375, 5), 1);
  assert.equal(snapIndex(5000, 375, 5), 4);
  assert.equal(stepIndex(0, 'ArrowRight', 3), 1);
  assert.equal(stepIndex(2, 'ArrowRight', 3), null);
  assert.equal(stepIndex(0, 'ArrowLeft', 3), null);
  assert.equal(stepIndex(1, 'Enter', 3), null);
});

test('the box and the rear wheel the body pivots on', () => {
  assert.deepEqual(parseBox('0.1,0.5,0.8,0.3'), { x: 0.1, y: 0.5, w: 0.8, h: 0.3 });
  assert.equal(parseBox('0.1,0.5,0.8'), null);
  assert.equal(parseBox('a,b,c,d'), null);
  assert.equal(parseBox(undefined), null);
  assert.deepEqual(rearPivot({ x: 0.1, y: 0.5, w: 0.8, h: 0.3 }, 'left'), { x: '74.0%', y: '80.0%' });
  assert.deepEqual(rearPivot({ x: 0.1, y: 0.5, w: 0.8, h: 0.3 }, 'right'), { x: '26.0%', y: '80.0%' });
});

test('only a plain click drives off; the page starts within the owner\'s 250 ms', () => {
  const e = { button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false };
  assert.equal(plainClick(e), true);
  assert.equal(plainClick({ ...e, metaKey: true }), false);
  assert.equal(plainClick({ ...e, button: 1 }), false);
  assert.ok(DRIVE_NAV_MS <= 250);
});

test('the slides: the gallery after the cover, no placeholder, at most n - 1', () => {
  const l = [{ path: 'a' }, { path: 'b' }, { path: 'c', placeholder: true }, { path: 'd' }, { path: 'e' }];
  assert.deepEqual(slidePhotos(l, 'a', 3).map((p) => p.path), ['b', 'd']);
  assert.deepEqual(slidePhotos(l, null, 2).map((p) => p.path), ['a']);
  assert.deepEqual(slidePhotos(l, 'a', 1), []);
});
