import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clampBox, forSave, fromCorners, inside, nearCorner } from './plate-cover.ts';

test('a box drawn in any direction is kept inside the photo', () => {
  assert.deepEqual(forSave([fromCorners({ x: 0.6, y: 0.7 }, { x: 0.4, y: 0.6 })]), [{ x: 0.4, y: 0.6, w: 0.2, h: 0.1 }]);
  const c = clampBox({ x: 0.95, y: 0.95, w: 0.2, h: 0.1 });
  assert.ok(c.x + c.w <= 1 && c.y + c.h <= 1);
  assert.equal(clampBox({ x: 0.5, y: 0.5, w: 0, h: 0 }).w, 0.01);
});
test('a point inside a box moves it; near its corner resizes it', () => {
  const b = { x: 0.4, y: 0.6, w: 0.2, h: 0.1 };
  assert.equal(inside(b, { x: 0.5, y: 0.65 }), true);
  assert.equal(inside(b, { x: 0.1, y: 0.65 }), false);
  assert.equal(nearCorner(b, { x: 0.6, y: 0.7 }), true);
});
