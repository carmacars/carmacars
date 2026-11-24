// The studio consistency gate (release 50, 3701): framing put on target, the wall, floor and contact shadow against the one
// plate, the view and the direction.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FRAME_ASK, FRAME_TOL, MAX_ZOOM, STUDIO_FRAME, cropResize, frameWindow, gateExterior, gateInterior, placementLine, readCarBox, type FBox } from './studio-gate.ts';
import type { Rgba } from './subject-frame.ts';
import { feedbackLine, r48Prompt, r48CheckPrompt, R48_CHECK_SCHEMA } from './r48.ts';

const W = 300, H = 200;
/** A studio: a charcoal wall above `horizon`, a darker floor below. */
function studio(wall = [40, 40, 44], floor = [22, 22, 24], horizon = 0.6): Rgba {
  const d = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const c = y < H * horizon ? wall : floor; const i = (y * W + x) * 4;
    d[i] = c[0]!; d[i + 1] = c[1]!; d[i + 2] = c[2]!; d[i + 3] = 255;
  }
  return { width: W, height: H, data: d };
}
/** The studio with a red car in `car` and a dark contact shadow under it. */
function withCar(base: Rgba, car: FBox, shadow = true): Rgba {
  const d = new Uint8ClampedArray(base.data);
  const fill = (b: FBox, c: number[]) => {
    for (let y = Math.floor(b.y * H); y < Math.ceil((b.y + b.h) * H); y++) for (let x = Math.floor(b.x * W); x < Math.ceil((b.x + b.w) * W); x++) {
      if (x < 0 || y < 0 || x >= W || y >= H) continue;
      const i = (y * W + x) * 4; d[i] = c[0]!; d[i + 1] = c[1]!; d[i + 2] = c[2]!;
    }
  };
  fill(car, [180, 20, 20]);
  if (shadow) fill({ x: car.x + car.w * 0.1, y: car.y + car.h - 0.015, w: car.w * 0.8, h: 0.03 }, [4, 4, 4]);
  return { width: W, height: H, data: d };
}
const onTarget = (shot: string): FBox => { const t = STUDIO_FRAME[shot]!; return { x: t.cx - t.width / 2, y: t.bottom - 0.35, w: t.width, h: 0.35 }; };

test('every outside view has a target, the inside views none; the model is asked a little smaller than the target', () => {
  for (const s of ['front_left', 'front', 'left', 'rear_left', 'rear']) assert.ok(STUDIO_FRAME[s], s);
  for (const s of ['dashboard', 'front_seats', 'rear_seats', 'trunk']) { assert.equal(STUDIO_FRAME[s], undefined); assert.equal(placementLine(s), ''); }
  assert.ok(FRAME_ASK < 1);
  assert.match(placementLine('front_left'), new RegExp(`${Math.round(STUDIO_FRAME.front_left!.width * FRAME_ASK * 100)} percent of the frame width`));
  assert.match(placementLine('left'), /exactly the background plate/);
});

test('the prompt carries the exact placement; the check asks for the car box; gate reasons are fed back', () => {
  const p = r48Prompt({ car: { make: 'Honda', model: 'Civic' }, shot: 'left', refs: 2, guide: false, stock: false, plate: true });
  assert.match(p, /EXACT PLACEMENT/);
  assert.match(r48CheckPrompt({ car: { make: 'Honda', model: 'Civic' }, shot: 'left', plate: true }), /"car_box"/);
  assert.ok('car_box' in R48_CHECK_SCHEMA.properties);
  assert.match(feedbackLine(['gate_wall_mismatch', 'gate_no_shadow']), /background plate.*contact shadow/);
});

test('readCarBox: the 0 to 1000 grid, y first; tiny or malformed boxes are refused', () => {
  assert.deepEqual(readCarBox({ car_box: [200, 100, 800, 900] }), { x: 0.1, y: 0.2, w: 0.8, h: 0.6000000000000001 });
  assert.equal(readCarBox({ car_box: [200, 100, 250, 150] }), null);
  assert.equal(readCarBox({ car_box: 'x' }), null);
  assert.equal(readCarBox(null), null);
});

test('frameWindow: a smaller car is cropped onto its target; a bigger one is refused; the zoom is capped', () => {
  const t = STUDIO_FRAME.front_left!;
  const small: FBox = { x: 0.15, y: 0.4, w: t.width * FRAME_ASK, h: 0.4 };
  const r = frameWindow(small, t);
  assert.ok(!('error' in r));
  if (!('error' in r)) {
    assert.ok(Math.abs(r.car.w - t.width) < 1e-9);
    assert.ok(Math.abs(r.car.x + r.car.w / 2 - t.cx) < FRAME_TOL.cx);
    assert.ok(Math.abs(r.car.y + r.car.h - t.bottom) < FRAME_TOL.bottom);
    assert.ok(r.win.x >= 0 && r.win.y >= 0 && r.win.x + r.win.w <= 1 + 1e-9 && r.win.y + r.win.h <= 1 + 1e-9);
  }
  assert.deepEqual(frameWindow({ x: 0.02, y: 0.2, w: 0.96, h: 0.6 }, t), { error: 'gate_car_too_big' });
  const tiny = frameWindow({ x: 0.4, y: 0.5, w: 0.3, h: 0.2 }, t);
  assert.ok(!('error' in tiny) && Math.abs(1 / tiny.win.w - MAX_ZOOM) < 1e-9, 'the zoom stops at MAX_ZOOM');
});

test('cropResize keeps the size and moves the content', () => {
  const img = withCar(studio(), { x: 0.5, y: 0.5, w: 0.2, h: 0.2 }, false);
  const out = cropResize(img, { x: 0.5, y: 0.5, w: 0.5, h: 0.5 }, W, H);
  assert.equal(out.width, W); assert.equal(out.height, H);
  const i = (Math.floor(H * 0.1) * W + Math.floor(W * 0.1)) * 4;
  assert.equal(out.data[i], 180, 'the car now fills the top left of the crop');
});

test('the gate passes a car on target in the plate, with its contact shadow, in the asked view and direction', () => {
  const plate = studio();
  const car = onTarget('front_left');
  const v = gateExterior({ shot: 'front_left', img: withCar(plate, car), plate, car, view: 'front_left', nose: 'left' });
  assert.equal(v.pass, true, v.reasons.join(','));
  assert.ok(v.measures.wall !== undefined && v.measures.wall < 0.01);
});

test('the gate refuses another background, another floor, no shadow, an off-target car, the wrong view or direction, no plate', () => {
  const plate = studio();
  const car = onTarget('left');
  const r = (o: Partial<Parameters<typeof gateExterior>[0]>) => gateExterior({ shot: 'left', img: withCar(plate, car), plate, car, view: 'left', nose: 'left', ...o }).reasons;
  assert.ok(r({ img: withCar(studio([200, 200, 200]), car) }).includes('gate_wall_mismatch'));
  assert.ok(r({ img: withCar(studio([40, 40, 44], [160, 150, 140]), car) }).includes('gate_floor_mismatch'));
  assert.ok(r({ img: withCar(plate, car, false) }).includes('gate_no_shadow'));
  assert.ok(r({ car: { ...car, x: car.x + 0.1 } }).includes('gate_car_off_target'));
  assert.ok(r({ car: { ...car, w: car.w * 0.8 } }).includes('gate_car_off_target'));
  assert.ok(r({ view: 'right' }).includes('gate_wrong_view'));
  assert.ok(r({ nose: 'right' }).includes('gate_wrong_direction'));
  assert.ok(r({ plate: null }).includes('gate_no_plate'));
  assert.ok(r({ car: null }).includes('gate_no_car_box'));
});

test('inside views: the view only', () => {
  assert.equal(gateInterior({ shot: 'dashboard', view: 'dashboard' }).pass, true);
  assert.deepEqual(gateInterior({ shot: 'trunk', view: 'rear_seats' }).reasons, ['gate_wrong_view']);
});
