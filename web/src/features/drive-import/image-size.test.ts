import { test } from 'node:test';
import assert from 'node:assert/strict';
import { imageSize } from './image-size.ts';

const be16 = (n: number) => [(n >> 8) & 255, n & 255];
const jpeg = (w: number, h: number, orientation?: number) => {
  const exif = orientation === undefined ? [] : (() => {
    // Exif header, big-endian TIFF, one entry (orientation)
    const tiff = [0x4d, 0x4d, 0, 0x2a, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, ...be16(orientation), 0, 0, 0, 0, 0, 0];
    const body = [0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff];
    return [0xff, 0xe1, ...be16(body.length + 2), ...body];
  })();
  return new Uint8Array([0xff, 0xd8, ...exif, 0xff, 0xc0, ...be16(17), 8, ...be16(h), ...be16(w), 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xff, 0xd9]);
};

test('a JPEG as it is', () => assert.deepEqual(imageSize(jpeg(4000, 3000)), { width: 4000, height: 3000, orientation: 1 }));
test('a JPEG held on its side swaps width and height', () => {
  assert.deepEqual(imageSize(jpeg(4000, 3000, 6)), { width: 3000, height: 4000, orientation: 6 });
  assert.deepEqual(imageSize(jpeg(4000, 3000, 3)), { width: 4000, height: 3000, orientation: 3 });
});
test('a PNG', () => {
  const b = new Uint8Array(33);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38]);
  assert.deepEqual(imageSize(b), { width: 1920, height: 1080, orientation: 1 });
});
test('anything else, or a broken file, has no size', () => {
  assert.equal(imageSize(new TextEncoder().encode('<html>')), null);
  assert.equal(imageSize(new Uint8Array([0xff, 0xd8, 0xff])), null);
  assert.equal(imageSize(new Uint8Array(0)), null);
});
