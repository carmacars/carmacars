import { test } from 'node:test';
import assert from 'node:assert/strict';
import { imageSniff, isPdf } from './file-sniff.ts';

const bytes = (...b: number[]) => new Uint8Array(b);

test('a JPEG and a PNG are known by their first bytes', () => {
  assert.deepEqual(imageSniff(bytes(0xff, 0xd8, 0xff, 0xe0)), { jpg: true, png: false });
  assert.deepEqual(imageSniff(bytes(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)), { jpg: false, png: true });
});

test('a file that only starts like an image, or is too short, is neither', () => {
  assert.deepEqual(imageSniff(bytes(0xff, 0xd8, 0x00)), { jpg: false, png: false });
  assert.deepEqual(imageSniff(bytes(0x89, 0x50)), { jpg: false, png: false });
  assert.deepEqual(imageSniff(new TextEncoder().encode('<svg onload=alert(1)>')), { jpg: false, png: false });
  assert.deepEqual(imageSniff(bytes()), { jpg: false, png: false });
});

test('a PDF starts with %PDF-', () => {
  assert.equal(isPdf(new TextEncoder().encode('%PDF-1.7\n')), true);
  assert.equal(isPdf(new TextEncoder().encode('%PDF')), false);
  assert.equal(isPdf(new TextEncoder().encode('<html>')), false);
});
