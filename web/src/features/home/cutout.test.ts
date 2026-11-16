// r48 O (3080): where a cutout is kept (features/home/cutout.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cutoutKey, largestBlobBox } from './cutout.ts';

test('a cutout gets a new name each time, under site/cutouts/<car>/', () => {
  assert.equal(cutoutKey('6247DF50-466E-4650-A513-5A533D3B9D50', 'left', 'abcdef0123456789'), 'site/cutouts/6247df50-466e-4650-a513-5a533d3b9d50/left-abcdef012345.webp');
  assert.throws(() => cutoutKey('../x', 'left', 'a'));
  assert.throws(() => cutoutKey('6247df50-466e-4650-a513-5a533d3b9d50', '../x', 'a'));
});

test('the car is the largest shape: lettering kept apart from it above is cropped off', () => {
  const w = 10, h = 8, a = new Uint8Array(w * h);
  for (let x = 1; x < 4; x++) a[1 * w + x] = 255; // a letter on the wall
  for (let y = 4; y < 7; y++) for (let x = 1; x < 9; x++) a[y * w + x] = 255; // the car
  assert.deepEqual(largestBlobBox(a, w, h), { left: 1, top: 4, width: 8, height: 3 });
  assert.equal(largestBlobBox(new Uint8Array(4), 2, 2), null);
});
