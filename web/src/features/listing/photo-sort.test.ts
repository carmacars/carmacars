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
