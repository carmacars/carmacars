import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fitScale, sourceKind, sourceProblem } from './formats.ts';

test('every common format is known by its type or its name', () => {
  assert.equal(sourceKind({ type: 'image/jpeg', name: 'a.jpg' }), 'jpeg');
  assert.equal(sourceKind({ type: 'image/png', name: 'a.png' }), 'png');
  assert.equal(sourceKind({ type: 'image/heic', name: 'IMG_0001.HEIC' }), 'heic');
  assert.equal(sourceKind({ type: '', name: 'IMG_0001.HEIC' }), 'heic');
  assert.equal(sourceKind({ type: 'image/heif', name: 'x' }), 'heic');
  assert.equal(sourceKind({ type: 'image/webp', name: 'x.webp' }), 'webp');
  assert.equal(sourceKind({ type: 'application/pdf', name: 'scan.pdf' }), 'pdf');
  assert.equal(sourceKind({ type: '', name: 'scan.PDF' }), 'pdf');
  assert.equal(sourceKind({ type: 'image/x-adobe-dng', name: 'x.dng' }), 'jpeg');
  assert.equal(sourceKind({ type: 'text/plain', name: 'a.txt' }), 'other');
});

test('clear refusals: empty, too large, not a photo', () => {
  assert.match(sourceProblem({ type: 'image/jpeg', name: 'a.jpg', size: 0 })!, /empty/);
  assert.match(sourceProblem({ type: 'image/jpeg', name: 'a.jpg', size: 50 * 1024 * 1024 })!, /40 MB/);
  assert.match(sourceProblem({ type: 'application/zip', name: 'a.zip', size: 10 })!, /JPG, PNG, HEIC, WEBP/);
  assert.equal(sourceProblem({ type: 'image/heic', name: 'a.heic', size: 3_000_000 }), null);
});

test('large photos are made smaller, small ones kept', () => {
  assert.equal(fitScale(4032, 3024), 2000 / 4032);
  assert.equal(fitScale(1200, 800), 1);
});
