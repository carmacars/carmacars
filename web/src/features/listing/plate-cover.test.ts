import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clampBox, forSave, fromCorners, inside, nearCorner, refineBox } from './plate-cover.ts';

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

/** A grey photo: a light background, a dark car, a white plate with dark characters at a known place. */
function photo(W: number, H: number, plate: { x: number; y: number; w: number; h: number }) {
  const data = new Uint8ClampedArray(W * H).fill(200);
  const fill = (x0: number, y0: number, x1: number, y1: number, v: number) => { for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) data[y * W + x] = v; };
  fill(Math.round(W * 0.2), Math.round(H * 0.4), Math.round(W * 0.8), Math.round(H * 0.85), 45);
  const px = Math.round(plate.x * W), py = Math.round(plate.y * H), pw = Math.round(plate.w * W), ph = Math.round(plate.h * H);
  fill(px, py, px + pw, py + ph, 245);
  for (let k = 0; k < 7; k++) { const x = px + Math.round(pw * (0.1 + k * 0.12)); fill(x, py + Math.round(ph * 0.2), x + Math.max(1, Math.round(pw * 0.05)), py + Math.round(ph * 0.8), 20); }
  return { width: W, height: H, data };
}
test('a rough plate box from the model is moved onto the plate (as the live model answered: across it, but too low)', () => {
  const plate = { x: 0.43, y: 0.7, w: 0.14, h: 0.078 };
  const r = refineBox(photo(360, 230, plate), { x: 0.444, y: 0.78, w: 0.111, h: 0.044 });
  assert.equal(r.moved, true);
  const cy = r.box.y + r.box.h / 2, cx = r.box.x + r.box.w / 2;
  assert.ok(Math.abs(cy - (plate.y + plate.h / 2)) < 0.035, `centre y ${cy.toFixed(3)}`);
  assert.ok(Math.abs(cx - (plate.x + plate.w / 2)) < 0.04, `centre x ${cx.toFixed(3)}`);
});
test('with nothing plate-like near it, the model\'s box stays', () => {
  const blank = { width: 200, height: 120, data: new Uint8ClampedArray(200 * 120).fill(128) };
  const g = { x: 0.4, y: 0.6, w: 0.2, h: 0.08 };
  const r = refineBox(blank, g);
  assert.equal(r.moved, false);
  assert.deepEqual(r.box, g);
});
