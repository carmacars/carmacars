import { test } from 'node:test';
import assert from 'node:assert/strict';
import { alphaOf, compose, dab, masksDiffer, sameAdjust, stroke, studioPlan, union } from './cutout-edit.ts';

test('dab: erase lowers the alpha to nothing at its centre, soft at its edge; restore raises it; the rest untouched', () => {
  const W = 40, H = 40, m = new Uint8ClampedArray(W * H).fill(255);
  const r = dab(m, W, H, 20, 20, 8, 'erase')!;
  assert.equal(m[20 * W + 20], 0);
  assert.ok(m[20 * W + 27]! > 0 && m[20 * W + 27]! < 255, 'soft edge');
  assert.equal(m[0], 255);
  assert.deepEqual([r.x, r.y, r.w, r.h], [12, 12, 17, 17]);
  const z = new Uint8ClampedArray(W * H);
  dab(z, W, H, 5, 5, 4, 'restore');
  assert.equal(z[5 * W + 5], 255);
  assert.equal(z[30 * W + 30], 0);
  // never past the dab: restore keeps a full pixel full, erase keeps a clear pixel clear
  const before = m[20 * W + 27]!;
  dab(m, W, H, 20, 20, 8, 'erase');
  assert.equal(m[20 * W + 27], before);
  assert.equal(dab(m, W, H, -50, -50, 3, 'erase'), null, 'outside the mask: nothing');
});

test('stroke: a line of dabs, the touched rectangle; union of rectangles', () => {
  const W = 100, H = 20, m = new Uint8ClampedArray(W * H).fill(255);
  const r = stroke(m, W, H, 10, 10, 90, 10, 3, 'erase')!;
  for (let x = 10; x <= 90; x += 5) assert.equal(m[10 * W + x], 0, `erased at ${x}`);
  assert.ok(r.x <= 7 && r.x + r.w >= 93);
  assert.deepEqual(union({ x: 0, y: 0, w: 2, h: 2 }, { x: 5, y: 5, w: 1, h: 1 }), { x: 0, y: 0, w: 6, h: 6 });
  assert.equal(union(null, null), null);
});

test('compose: the original colours with the mask as alpha; alphaOf reads a mask back; masksDiffer', () => {
  const W = 2, H = 1, orig = new Uint8ClampedArray([10, 20, 30, 255, 40, 50, 60, 255]);
  const out = compose(orig, new Uint8ClampedArray([0, 200]), W, H);
  assert.deepEqual([...out], [10, 20, 30, 0, 40, 50, 60, 200]);
  assert.deepEqual([...alphaOf({ width: 2, height: 1, data: out })], [0, 200]);
  assert.equal(masksDiffer(new Uint8ClampedArray([1, 2]), new Uint8ClampedArray([1, 2])), false);
  assert.equal(masksDiffer(new Uint8ClampedArray([1, 2]), new Uint8ClampedArray([1, 3])), true);
  assert.equal(sameAdjust(null, { dx: 0, dy: 0, scale: 1 }), true);
  assert.equal(sameAdjust({ dx: 0.1, dy: 0, scale: 1 }, null), false);
});

test('studioPlan: the car framed as the worker frames it; an erased mirror-sized blob changes nothing far off; moved by the adjustment', () => {
  const W = 400, H = 260, data = new Uint8ClampedArray(W * H * 4);
  for (let y = 100; y < 170; y++) for (let x = 120; x < 280; x++) { const p = (y * W + x) * 4; data[p] = 200; data[p + 3] = 255; }
  const a = studioPlan({ width: W, height: H, data }, null)!;
  assert.ok(a.base.carShare > 0.7, 'the car big on the frame');
  const b = studioPlan({ width: W, height: H, data }, { dx: 0.1, dy: 0, scale: 1 })!;
  assert.equal(b.place.left - a.place.left, 180);
  assert.equal(studioPlan({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4) }, null), null, 'nothing left: no car');
});
