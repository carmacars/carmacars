// r48 O (3080): where a cutout is kept (features/home/cutout.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cutoutKey } from './cutout.ts';

test('a cutout gets a new name each time, under site/cutouts/<car>/', () => {
  assert.equal(cutoutKey('6247DF50-466E-4650-A513-5A533D3B9D50', 'left', 'abcdef0123456789'), 'site/cutouts/6247df50-466e-4650-a513-5a533d3b9d50/left-abcdef012345.webp');
  assert.throws(() => cutoutKey('../x', 'left', 'a'));
  assert.throws(() => cutoutKey('6247df50-466e-4650-a513-5a533d3b9d50', '../x', 'a'));
});
