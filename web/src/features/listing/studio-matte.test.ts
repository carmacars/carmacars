// The drive-off matte (studio-matte.ts).   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gateFrame, matteRgba, matteUsable, studioMatte } from './studio-matte.ts';
import type { Rgba } from './subject-frame.ts';

const W = 900, H = 600;
// a studio: a lit wall fading to a dark floor (the plate)
function plate(): Rgba {
  const d = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const o = (y * W + x) * 4, v = y < 0.74 * H ? 70 - (y / H) * 40 : 34 - ((y - 0.74 * H) / H) * 30;
    d[o] = v; d[o + 1] = v; d[o + 2] = v + 2; d[o + 3] = 255;
  }
  return { width: W, height: H, data: d };
}
const car = { x: 0.1, y: 0.5, w: 0.8, h: 0.3 };
// the render: the plate, a car (body, a window showing the wall, two black wheels), its contact shadow under and beside it,
// and a little noise everywhere (a model never redraws the plate exactly)
function render(): Rgba {
  const img = plate(), d = img.data;
  let seed = 7; const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647 - 0.5) * 8;
  const floor = (car.y + car.h) * H;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const o = (y * W + x) * 4, fx = x / W, fy = y / H;
    let c: number | null = null;
    const inBody = fx > car.x && fx < car.x + car.w && fy > car.y + 0.08 && fy < car.y + car.h - 0.06;
    const inRoof = fx > car.x + 0.2 && fx < car.x + car.w - 0.2 && fy > car.y && fy <= car.y + 0.08;
    const inWindow = fx > car.x + 0.25 && fx < car.x + car.w - 0.25 && fy > car.y + 0.015 && fy < car.y + 0.07;
    const wheel = (cx: number) => Math.hypot(fx - cx, (fy - (car.y + car.h - 0.06)) * 1.5) < 0.06;
    if (inBody || inRoof) c = 160;
    if (inWindow) c = null; // glass: the wall shows through
    if (wheel(car.x + 0.15) || wheel(car.x + car.w - 0.15)) c = 8;
    if (c !== null) { d[o] = c; d[o + 1] = c - 20; d[o + 2] = c - 40; }
    // the contact shadow: under the car and a little past both ends, below the floor line
    if (y > floor && y < floor + 14 && fx > car.x - 0.05 && fx < car.x + car.w + 0.05) { d[o] = d[o]! * 0.4; d[o + 1] = d[o + 1]! * 0.4; d[o + 2] = d[o + 2]! * 0.4; }
    d[o] = d[o]! + rnd(); d[o + 1] = d[o + 1]! + rnd(); d[o + 2] = d[o + 2]! + rnd();
  }
  return img;
}
const at = (m: { width: number; height: number; alpha: Uint8Array }, fx: number, fy: number) => m.alpha[Math.floor(fy * m.height) * m.width + Math.floor(fx * m.width)]!;

test('the matte is the car: body, window and wheels in, the wall, the floor and the shadow out', () => {
  const m = studioMatte(render(), plate(), car);
  assert.equal(m.width, 480); assert.equal(m.height, 320);
  assert.equal(at(m, 0.5, 0.65), 255, 'the body');
  assert.equal(at(m, 0.5, 0.54), 255, 'the window (glass shows the wall but is the car)');
  assert.equal(at(m, 0.25, 0.74), 255, 'a wheel');
  assert.equal(at(m, 0.5, 0.2), 0, 'the wall');
  assert.equal(at(m, 0.05, 0.65), 0, 'the wall beside the car');
  assert.equal(at(m, 0.04, 0.815), 0, 'the shadow past the front');
  assert.equal(at(m, 0.5, 0.9), 0, 'the floor');
  assert.ok(matteUsable(m, car));
});

test('a render that is the plate (no car found) is not usable', () => {
  const m = studioMatte(plate(), plate(), car);
  assert.equal(m.fill, 0);
  assert.equal(matteUsable(m, car), false);
});

test('the matte image: black, the car in the alpha', () => {
  const m = studioMatte(render(), plate(), car);
  const img = matteRgba(m);
  assert.equal(img.data.length, 480 * 320 * 4);
  const i = (Math.floor(0.65 * 320) * 480 + 240) * 4;
  assert.deepEqual([...img.data.slice(i, i + 4)], [0, 0, 0, 255]);
});

test('the gate frame is read from r45, and refused when missing or broken', () => {
  const g = { gate: { win: { x: 0.05, y: 0.02, w: 0.9, h: 0.9 }, measures: { car: { x: 0.08, y: 0.4, w: 0.84, h: 0.42 } } } };
  assert.deepEqual(gateFrame(g), { win: g.gate.win, car: g.gate.measures.car });
  assert.equal(gateFrame({ gate: { measures: { car: g.gate.measures.car } } }), null);
  assert.equal(gateFrame({ gate: { win: g.gate.win, measures: { car: { x: 0, y: 0, w: 0.05, h: 0.4 } } } }), null);
  assert.equal(gateFrame(null), null);
});
