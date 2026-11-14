// r43 (2690): the first photo of a car. node --test (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isExteriorShot, orderPhotos, photoRank, primaryNotExterior, primaryPhoto } from './photo-order.ts';

test('the front three-quarter is first, then the other exterior shots, then the inside', () => {
  const shots = ['dashboard', 'rear', 'front_seats', 'front_left', 'left', 'other', 'front', 'wheel', 'front_right'];
  assert.deepEqual(orderPhotos(shots.map((shot) => ({ shot }))).map((p) => p.shot),
    ['front_left', 'front', 'left', 'rear', 'front_right', 'dashboard', 'front_seats', 'wheel', 'other']);
});

test('an interior photo marked cover or first in the list is never first while an exterior exists', () => {
  const photos = [{ shot: 'dashboard', is_cover: true, sort_order: 0 }, { shot: 'front_seats', sort_order: 1 }, { shot: 'rear', sort_order: 5 }, { shot: 'front_left', sort_order: 9 }];
  assert.equal(primaryPhoto(photos)?.shot, 'front_left');
  assert.equal(primaryNotExterior(photos), false);
});

test('a car without the standard angle gets its best exterior', () => {
  assert.equal(primaryPhoto([{ shot: 'dashboard' }, { shot: 'rear' }, { shot: 'left' }])?.shot, 'left');
  assert.equal(primaryPhoto([{ shot: 'dashboard' }, { shot: 'rear' }, { shot: 'front' }])?.shot, 'front');
});

test('a car with no exterior keeps its order and is flagged', () => {
  const photos = [{ shot_type: 'front_seats', sort_order: 2 }, { shot_type: 'dashboard', sort_order: 1 }];
  assert.equal(primaryPhoto(photos)?.shot_type, 'dashboard');
  assert.equal(primaryNotExterior(photos), true);
  assert.equal(primaryNotExterior([]), false);
  assert.equal(primaryPhoto(null), null);
});

test('same shot: the cover, then the order; the sort is stable', () => {
  const a = { shot: 'other', sort_order: 3, id: 'a' }, b = { shot: 'other', sort_order: 1, id: 'b' }, c = { shot: 'other', sort_order: 1, id: 'c', is_cover: true };
  assert.deepEqual(orderPhotos([a, b, c]).map((x) => x.id), ['c', 'b', 'a']);
  const d = { shot: 'rear', id: 'd' }, e = { shot: 'rear', id: 'e' };
  assert.deepEqual(orderPhotos([e, d]).map((x) => x.id), ['e', 'd']);
});

test('a made cover stays first; ranks match the database', () => {
  assert.equal(primaryPhoto([{ shot: 'front_left' }, { shot: 'cover_flyer' }])?.shot, 'cover_flyer');
  assert.deepEqual(['front_left', 'front', 'left', 'rear_left', 'rear', 'front_right', 'right', 'rear_right', 'exterior_more', 'dashboard', 'trunk', null].map(photoRank), [0, 1, 2, 3, 4, 5, 6, 7, 8, 20, 23, 30]);
  assert.equal(isExteriorShot('front_left'), true);
  assert.equal(isExteriorShot('trunk'), false);
  assert.equal(isExteriorShot('toString'), false);
});
