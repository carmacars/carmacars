// The studio gate and composite of r48.4 (R50 hotfix 2, 5080): the key colour read and taken out, the gate on a flat key and
// the whole car, and the car put on the drawn dealership at its view's place, the same for every car.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { KEY_BORDER_MIN, STUDIO_FRAME, chromaKey, cropResize, gateKey, keyFor, keyness } from './studio-gate.ts';
import { composeStudio, fitFor } from './studio-composite.ts';
import { showroomBackdrop } from './showroom.ts';
import type { Rgba } from './subject-frame.ts';

const W = 300, H = 200;
/** A flat background with a grey car (dark wheels) from x0 to x1. */
function frame(bg: [number, number, number], x0 = 0.15, x1 = 0.85, y0 = 0.35, y1 = 0.7): Rgba {
  const carColour = [150, 152, 158] as const, wy = (y1 - y0) * 0.23;
  const d = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const fx = x / W, fy = y / H, i = (y * W + x) * 4;
    let c: readonly number[] = bg;
    const k = x1 - x0;
    if (fx >= x0 && fx <= x1 && fy >= y0 && fy <= y1) c = carColour;
    if (fy > y1 - wy && fy <= y1 + wy * 0.25 && ((fx >= x0 + k * 0.1 && fx <= x0 + k * 0.28) || (fx >= x1 - k * 0.28 && fx <= x1 - k * 0.1))) c = [20, 20, 20];
    d[i] = c[0]!; d[i + 1] = c[1]!; d[i + 2] = c[2]!; d[i + 3] = 255;
  }
  return { width: W, height: H, data: d };
}

test('the key: green, magenta for a green car; grey, white, black and red paint are never key', () => {
  assert.equal(keyFor('Polar White'), 'green');
  assert.equal(keyFor('British Racing Green'), 'magenta');
  assert.equal(keyFor('Olive'), 'magenta');
  assert.equal(keyFor(null), 'green');
  assert.equal(keyness(0, 255, 0, 'green'), 1);
  assert.equal(keyness(30, 200, 60, 'green'), 1, 'a key a little off pure green is still key');
  for (const c of [[128, 128, 128], [250, 250, 250], [10, 10, 10], [200, 20, 30], [110, 140, 110]] as const) assert.equal(keyness(c[0], c[1], c[2], 'green'), 0, String(c));
  assert.equal(keyness(255, 0, 255, 'magenta'), 1);
  assert.equal(keyness(40, 160, 60, 'magenta'), 0, 'a green car on magenta stays car');
});

test('chromaKey: the background clear, the car opaque, its box; the green spill taken off the edge', () => {
  const k = chromaKey(frame([0, 255, 0]), 'green');
  assert.ok(k.border > 0.99 && k.edge === 0, JSON.stringify({ b: k.border, e: k.edge }));
  assert.ok(k.box && Math.abs(k.box.x - 0.15) < 0.01 && Math.abs(k.box.w - 0.7) < 0.01 && Math.abs(k.box.y - 0.35) < 0.01, JSON.stringify(k.box));
  assert.equal(k.cut.data[3], 0, 'the corner is clear');
  const mid = ((H / 2) * W + W / 2) * 4;
  assert.equal(k.cut.data[mid + 3], 255, 'the car is opaque');
  // a half-key edge pixel keeps no green cast
  const e = chromaKey({ width: 1, height: 1, data: new Uint8ClampedArray([80, 180, 90, 255]) }, 'green');
  assert.ok(e.cut.data[1]! <= Math.max(e.cut.data[0]!, e.cut.data[2]!));
});

test('the gate: a flat key and the whole car pass; a room, a car cut off by the frame or no car are refused', () => {
  assert.deepEqual(gateKey(chromaKey(frame([0, 255, 0]), 'green')).reasons, []);
  const roomy = gateKey(chromaKey(frame([60, 60, 64]), 'green'));
  assert.ok(roomy.reasons.includes('gate_key_background'));
  assert.ok((roomy.measures.border ?? 1) < KEY_BORDER_MIN);
  assert.deepEqual(gateKey(chromaKey(frame([0, 255, 0], 0, 0.9), 'green')).reasons, ['gate_key_cropped']);
  assert.deepEqual(gateKey(chromaKey(frame([0, 255, 0], 0.45, 0.55), 'green')).reasons, ['gate_key_no_car']);
  assert.equal(gateKey(null).pass, true, 'inside views are not keyed: the check judges them');
});

test('the composite: every car of a view at the same place on the same drawn room; the empty room is the same room', () => {
  const big = chromaKey(frame([0, 255, 0], 0.05, 0.95), 'green');
  const small = chromaKey(frame([0, 255, 0], 0.3, 0.7, 0.45, 0.6), 'green');
  const a = composeStudio(big.cut, 'front_left', 'CLA')!, b = composeStudio(small.cut, 'front_left', 'CLA')!;
  assert.equal(a.img.width, 1800);
  assert.equal(a.img.height, 1200);
  const t = STUDIO_FRAME.front_left!;
  for (const c of [a, b]) {
    assert.ok(Math.abs(c.car.w - t.width) < 0.03, JSON.stringify(c.car));
    assert.ok(Math.abs(c.car.x + c.car.w / 2 - t.cx) < 0.02, JSON.stringify(c.car));
    assert.ok(Math.abs(c.car.y + c.car.h - t.bottom) < 0.03, JSON.stringify(c.car));
  }
  // the room around the car is the drawn room, pixel for pixel (the top band, above the car and the name)
  const room = showroomBackdrop({ model: 'CLA', cover: true, carTop: a.car.y * 1200 });
  let same = 0, n = 0;
  for (let y = 0; y < 100; y += 7) for (let x = 0; x < 1800; x += 13) { const i = (y * 1800 + x) * 4; n++; if (Math.abs(a.img.data[i]! - room.data[i]!) <= 1) same++; }
  assert.equal(same, n);
  assert.deepEqual(a.backdrop.data.subarray(0, 4000), room.data.subarray(0, 4000));
  assert.deepEqual(fitFor('front'), { carWidth: 0.6, carHeight: 0.56, floor: 1 - 0.84 });
  assert.equal(composeStudio({ width: 10, height: 10, data: new Uint8ClampedArray(400) }, 'left', null), null, 'nothing to frame');
});

test('cropResize keeps the size and moves the content (the drive-off matte)', () => {
  const img = frame([0, 255, 0]);
  const out = cropResize(img, { x: 0, y: 0, w: 1, h: 1 }, W, H);
  assert.equal(out.width, W);
  assert.equal(out.data[((H / 2) * W + W / 2) * 4], img.data[((H / 2) * W + W / 2) * 4]);
});
