// Listing photos in any order (release 28, B8): where each photo is filed.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileAs, parseSort } from './photo-sort.ts';

test('the model names a free shot: filed there; outside shots are exterior (the studio)', () => {
  assert.deepEqual(fileAs(parseSort({ shot: 'front_left', watermark: false }), new Set()), { shot: 'front_left', watermark: false, exterior: true });
  assert.deepEqual(fileAs(parseSort({ shot: 'dashboard' }), new Set()), { shot: 'dashboard', watermark: false, exterior: false });
});

test('a shot already taken never replaces the photo: extra outside or extra detail', () => {
  assert.equal(fileAs(parseSort({ shot: 'rear' }), new Set(['rear'])).shot, 'exterior_more');
  assert.equal(fileAs(parseSort({ shot: 'trunk' }), new Set(['trunk'])).shot, 'other');
  assert.equal(fileAs(parseSort({ shot: 'exterior_other' }), new Set()).shot, 'exterior_more');
  assert.equal(fileAs(parseSort({ shot: 'interior_other' }), new Set()).shot, 'other');
});

test('no answer, or an unknown shot: a detail photo, never the studio', () => {
  assert.deepEqual(fileAs(null, new Set()), { shot: 'other', watermark: false, exterior: false });
  assert.equal(parseSort({ shot: 'roof rack' }), null);
  assert.equal(parseSort('nonsense'), null);
  assert.equal(parseSort({ shot: 'Front Left' })!.shot, 'front_left');
});

test('a watermark is passed on', () => {
  assert.equal(fileAs(parseSort({ shot: 'front_seats', watermark: true }), new Set()).watermark, true);
  assert.equal(parseSort({ shot: 'rear', watermark: 'true' })!.watermark, true);
});

// r28 (0567): where a mark is on an inside or detail photo, and the edge cut that takes it off
import { cropAway, parseMarks } from './photo-sort.ts';
test('the marks are read as fractions whatever scale the model answers in', () => {
  const size = { width: 1600, height: 1200 };
  assert.deepEqual(parseMarks({ marks: [{ x: 0.8, y: 0.9, w: 0.15, h: 0.06 }] }, size), [{ x: 0.8, y: 0.9, w: 0.15, h: 0.06 }]);
  assert.deepEqual(parseMarks({ marks: [{ x: 80, y: 90, w: 15, h: 6 }] }, size)!.map((b) => +b.x.toFixed(2)), [0.8]);
  assert.deepEqual(parseMarks({ marks: [{ x: 1280, y: 1080, w: 240, h: 72 }] }, size)!.map((b) => [+b.x.toFixed(2), +b.y.toFixed(2)]), [[0.8, 0.9]]);
  assert.deepEqual(parseMarks({ marks: [] }, size), []);
  assert.equal(parseMarks({ shot: 'front' }, size), null);
  assert.deepEqual(parseMarks({ marks: [{ x: 'a' }, null, { x: 0.1, y: 0.1, w: 0, h: 0.1 }] }, size), []);
});
test('a corner mark and a caption are cut off at the edges with the least lost; a mark in the middle is not', () => {
  assert.deepEqual(cropAway([{ x: 0.82, y: 0.9, w: 0.16, h: 0.07 }]), { top: 0, right: 0, bottom: 0.115, left: 0 });
  const two = cropAway([{ x: 0.82, y: 0.9, w: 0.16, h: 0.07 }, { x: 0.02, y: 0.02, w: 0.5, h: 0.06 }])!;
  assert.deepEqual(two, { top: 0.095, right: 0, bottom: 0.115, left: 0 });
  assert.equal(cropAway([{ x: 0.3, y: 0.3, w: 0.4, h: 0.4 }]), null);
  assert.deepEqual(cropAway([]), { top: 0, right: 0, bottom: 0, left: 0 });
});
