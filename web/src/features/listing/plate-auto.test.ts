import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PLATE_AUTO_PROMPT_GEMINI, boxesForSave, decidePlate, dedupeBoxes, greyOfRgba, iou, onCarPlate, plateAutoPrompt, refineAll, toPx } from './plate-auto.ts';
import { autoShown, autoText } from './plate-auto-view.ts';

// r41 (2530): the automatic plate check's decisions and its box handling.
const size = { width: 1000, height: 667 };
const plate = (x1: number, y1: number, x2: number, y2: number, confidence: number) => ({ x1, y1, x2, y2, confidence });

test('a plate the model is sure of is covered, with a margin, inside the photo', () => {
  const d = decidePlate({ plates: [plate(420, 450, 580, 492, 88)], plate_visible: 'yes', confidence: 90 }, { ...size, inside: false });
  assert.equal(d.decision, 'cover');
  assert.equal(d.confidence, 88);
  assert.equal(d.boxes.length, 1);
  const b = d.boxes[0]!;
  assert.ok(b.x < 0.42 && b.x + b.w > 0.58, 'the box covers the plate across, with a margin');
  assert.ok(b.y < 450 / 667 && b.y + b.h > 492 / 667, 'and up and down');
});

test('a weak second plate is covered with a strong one; alone it leaves the photo for a person', () => {
  const both = decidePlate({ plates: [plate(420, 450, 580, 492, 80), plate(100, 500, 180, 520, 35)] }, { ...size, inside: false });
  assert.equal(both.decision, 'cover');
  assert.equal(both.boxes.length, 2);
  const weak = decidePlate({ plates: [plate(100, 500, 180, 520, 35)], plate_visible: 'unsure', confidence: 50 }, { ...size, inside: true });
  assert.equal(weak.decision, 'unsure', 'a possible plate is never cleared, even on an inside shot');
});

test('no plate: cleared only when the model is sure; an inside shot by default', () => {
  assert.equal(decidePlate({ plates: [], plate_visible: 'no', confidence: 95 }, { ...size, inside: false }).decision, 'no_plate');
  assert.equal(decidePlate({ plates: [], plate_visible: 'no', confidence: 70 }, { ...size, inside: false }).decision, 'unsure');
  assert.equal(decidePlate({ plates: [], plate_visible: 'unsure', confidence: 40 }, { ...size, inside: false }).decision, 'unsure');
  assert.equal(decidePlate({ plates: [], plate_visible: 'unsure', confidence: 40 }, { ...size, inside: true }).decision, 'no_plate');
  assert.equal(decidePlate({ plates: [], plate_visible: 'yes', confidence: 80 }, { ...size, inside: true }).decision, 'unsure', 'a plate seen but not placed waits for a person');
  assert.equal(decidePlate({ plates: [], plate_visible: 'no', confidence: 0.9 }, { ...size, inside: false }).decision, 'no_plate', 'a 0 to 1 confidence is read as a share');
});

test('the thresholds come from Program settings', () => {
  const a = { plates: [plate(420, 450, 580, 492, 60)], plate_visible: 'yes', confidence: 60 };
  assert.equal(decidePlate(a, { ...size, inside: false, coverMin: 55 }).decision, 'cover');
  assert.equal(decidePlate(a, { ...size, inside: false, coverMin: 70 }).decision, 'unsure');
  assert.equal(decidePlate({ plates: [], plate_visible: 'no', confidence: 80 }, { ...size, inside: false, clearMin: 75 }).decision, 'no_plate');
});

test('an answer that is not one is left for a person', () => {
  for (const a of [null, 'no plate', {}, { plate_visible: 'no', confidence: 99 }]) assert.equal(decidePlate(a, { ...size, inside: false }).decision, 'unsure');
  // a box that is not plate shaped (a tall strip) is dropped by the shape check, and the rest of the answer decides
  assert.equal(decidePlate({ plates: [plate(100, 100, 120, 400, 90)], plate_visible: 'no', confidence: 95 }, { ...size, inside: false }).decision, 'no_plate');
});

test('the same plate answered twice is covered once, the surer box kept', () => {
  const a = { x: 0.4, y: 0.6, w: 0.2, h: 0.08, confidence: 70 }, b = { x: 0.41, y: 0.61, w: 0.2, h: 0.08, confidence: 90 }, c = { x: 0.1, y: 0.6, w: 0.1, h: 0.05, confidence: 60 };
  assert.ok(iou(a, b) > 0.6 && iou(a, c) === 0);
  assert.deepEqual(dedupeBoxes([a, b, c]).map((x) => x.confidence), [90, 60]);
});

test('boxes in pixels stay inside the image and at least 2 px; saved with four decimals', () => {
  assert.deepEqual(toPx({ x: 0.95, y: 0.95, w: 0.2, h: 0.2 }, 100, 100), { x: 80, y: 80, w: 20, h: 20 });
  const px = toPx({ x: 0, y: 0, w: 0.001, h: 0.001 }, 100, 100);
  assert.ok(px.w >= 1 && px.h >= 1 && px.x === 0 && px.y === 0);
  assert.deepEqual(boxesForSave([{ x: 0.123456, y: 0.5, w: 0.2, h: 0.07, suggested: true }]), [{ x: 0.1235, y: 0.5, w: 0.2, h: 0.07 }]);
  assert.deepEqual(boxesForSave([{ x: -0.1, y: 0.98, w: 0.2, h: 0.1 }]), [{ x: 0, y: 0.9, w: 0.2, h: 0.1 }]);
});

test('the grey image and the refined boxes (no grey: the boxes as given, clamped)', () => {
  const W = 40, H = 30, data = new Uint8ClampedArray(W * H * 4).fill(255);
  const g = greyOfRgba({ width: W, height: H, data }, 20);
  assert.equal(g.width, 20); assert.equal(g.height, 15); assert.equal(g.data[0], 255);
  assert.deepEqual(refineAll(null, [{ x: 0.9, y: 0.5, w: 0.3, h: 0.1 }]), [{ x: 0.7, y: 0.5, w: 0.3, h: 0.1 }]);
  const r = refineAll(g, [{ x: 0.4, y: 0.5, w: 0.2, h: 0.08 }])[0]!;
  assert.ok(r.x >= 0 && r.y >= 0 && r.x + r.w <= 1 && r.y + r.h <= 1);
});

test('the prompt gives the size in pixels and asks whether a plate is visible', () => {
  const p = plateAutoPrompt({ width: 1024, height: 683 });
  assert.match(p, /1024 pixels wide and 683 pixels high/);
  assert.match(p, /"plate_visible"/);
});

test('the review shows an automatic decision only while it is the photo\'s current one', () => {
  const auto = { who: 'auto', decision: 'covered' as const, confidence: 88, path: 'vehicles/x/a.jpg' };
  assert.equal(autoShown({ plate_status: 'covered', processed_path: 'vehicles/x/a.jpg', plate_auto: auto }), true);
  assert.equal(autoShown({ plate_status: 'covered', processed_path: 'vehicles/x/b.jpg', plate_auto: auto }), false, 'a person covered it again since');
  assert.equal(autoShown({ plate_status: 'covered', processed_path: 'vehicles/x/a.jpg', plate_auto: auto, plate_checked_by: 'u' }), false);
  assert.equal(autoShown({ plate_status: 'covered', processed_path: 'vehicles/x/a.jpg', plate_auto: { ...auto, undone: true } }), false);
  assert.equal(autoText(auto), 'Covered automatically (88% sure)');
  assert.equal(autoText({ who: 'auto', decision: 'not_visible', confidence: null }), 'No plate seen automatically');
  assert.equal(autoText(null), null);
});

// r44: the owner saw the plate drawn somewhere random: the CarmaCars sign or the model's name on the showroom wall was taken
// for a plate. A box where no plate can be is never covered, and never lets the photo be cleared either.
test('r44: a box on the wall (the logo sign, the model name) is never covered', () => {
  const sign = plate(250, 60, 750, 160, 90);      // high and wide: the lit logo
  const name = plate(400, 230, 600, 270, 80);     // high: the lettering
  const d = decidePlate({ plates: [sign, name], plate_visible: 'yes', confidence: 90 }, { ...size, inside: false });
  assert.notEqual(d.decision, 'cover');
  assert.equal(d.boxes.length, 0);
  const sure = decidePlate({ plates: [sign], plate_visible: 'no', confidence: 99 }, { ...size, inside: false });
  assert.equal(sure.decision, 'unsure', 'a wall box still stops the photo being cleared by itself');
});

test('r44: the real plate is covered and the wall box beside it is left alone', () => {
  const d = decidePlate({ plates: [plate(250, 60, 750, 160, 95), plate(420, 450, 580, 492, 88)] }, { ...size, inside: false });
  assert.equal(d.decision, 'cover');
  assert.equal(d.boxes.length, 1);
  assert.ok(d.boxes[0]!.y > 0.6, 'only the bumper plate');
});

test('r44: the plate zone', () => {
  assert.equal(onCarPlate({ x: 0.45, y: 0.7, w: 0.12, h: 0.05 }), true);
  assert.equal(onCarPlate({ x: 0.3, y: 0.1, w: 0.12, h: 0.05 }), false, 'too high');
  assert.equal(onCarPlate({ x: 0.2, y: 0.7, w: 0.4, h: 0.05 }), false, 'too wide for a plate');
});

test('r44: Gemini\'s box_2d (y first, 0 to 1000) lands on the plate, not swapped', () => {
  const d = decidePlate({ plates: [{ box_2d: [675, 420, 738, 580], confidence: 90 }], plate_visible: 'yes', confidence: 90 }, { ...size, inside: false });
  assert.equal(d.decision, 'cover');
  const b = d.boxes[0]!;
  assert.ok(b.x < 0.42 && b.x + b.w > 0.58 && b.y < 0.675 && b.y + b.h > 0.738, JSON.stringify(b));
  assert.match(PLATE_AUTO_PROMPT_GEMINI, /box_2d/);
  assert.match(PLATE_AUTO_PROMPT_GEMINI, /not a plate/);
});

test('r44: an inside shot keeps every box (the zone is for outside photos)', () => {
  assert.equal(decidePlate({ plates: [plate(250, 60, 450, 120, 90)] }, { ...size, inside: true }).decision, 'cover');
});
