import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fitWithin, isShrinkable, PHOTO, ID_PHOTO, shrinkImage } from './image-shrink.ts';

test('a 12 MP phone photo fits 2048 px on its long side, the shape kept', () => {
  assert.deepEqual(fitWithin(4032, 3024, PHOTO.maxEdge), { width: 2048, height: 1536, scale: 2048 / 4032 });
  const p = fitWithin(3024, 4032, PHOTO.maxEdge);
  assert.equal(p.height, 2048); assert.equal(p.width, 1536);
});

test('a smaller photo is never enlarged', () => {
  assert.deepEqual(fitWithin(1600, 1200, PHOTO.maxEdge), { width: 1600, height: 1200, scale: 1 });
  assert.deepEqual(fitWithin(2048, 100, PHOTO.maxEdge), { width: 2048, height: 100, scale: 1 });
});

test('a very long thin image keeps at least one pixel', () => {
  const p = fitWithin(100000, 10, PHOTO.maxEdge);
  assert.equal(p.width, 2048); assert.equal(p.height, 1);
});

test('no size read: nothing to draw', () => {
  assert.deepEqual(fitWithin(0, 0, 2048), { width: 0, height: 0, scale: 1 });
  assert.deepEqual(fitWithin(Number.NaN, 10, 2048), { width: 0, height: 0, scale: 1 });
});

test('the presets: photos 2048 px at JPEG 80, licences and selfies 2560 px at 85', () => {
  assert.deepEqual(PHOTO, { maxEdge: 2048, quality: 0.8 });
  assert.deepEqual(ID_PHOTO, { maxEdge: 2560, quality: 0.85 });
  assert.equal(fitWithin(4000, 3000, ID_PHOTO.maxEdge).width, 2560);
});

test('only photos are redrawn: PDFs, SVG drawings and GIFs stay as sent', () => {
  for (const t of ['image/jpeg', 'image/png', 'image/heic', 'image/webp', 'IMAGE/JPEG', '']) assert.equal(isShrinkable(t), true, t);
  for (const t of ['application/pdf', 'image/svg+xml', 'image/gif', 'text/plain']) assert.equal(isShrinkable(t), false, t);
});

test('outside a browser (or a PDF) the file comes back untouched', async () => {
  const pdf = new Blob(['%PDF-1.7'], { type: 'application/pdf' });
  const r = await shrinkImage(pdf);
  assert.equal(r.blob, pdf); assert.equal(r.shrunk, false); assert.equal(r.width, 0);
  const jpg = new Blob([new Uint8Array([0xff, 0xd8, 0xff])], { type: 'image/jpeg' });
  assert.equal((await shrinkImage(jpg)).blob, jpg);
});
