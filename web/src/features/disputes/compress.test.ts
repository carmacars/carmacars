import { test } from 'node:test';
import assert from 'node:assert/strict';
import jpeg from 'jpeg-js';
import { compressToFit, shareOf } from './compress.ts';

function noisy(w: number, h: number): Uint8Array {
  const data = new Uint8Array(w * h * 4);
  for (let i = 0; i < data.length; i += 4) { data[i] = (i * 7) % 255; data[i + 1] = (i * 13) % 251; data[i + 2] = (i * 3) % 241; data[i + 3] = 255; }
  return new Uint8Array(jpeg.encode({ width: w, height: h, data: data as unknown as Buffer }, 95).data);
}

test('a photo that fits is kept as it is', async () => {
  const b = noisy(64, 48);
  const r = await compressToFit(b, b.length + 10);
  assert.ok(r && !r.compressed && r.bytes === b);
});

test('a photo too big is made smaller, not dropped', async () => {
  const b = noisy(1600, 1200);
  const target = Math.floor(b.length / 8);
  const r = await compressToFit(b, target);
  assert.ok(r && r.compressed && r.jpeg);
  assert.ok(r.bytes.length <= target, `${r.bytes.length} > ${target}`);
});

test('not an image: null', async () => {
  assert.equal(await compressToFit(new Uint8Array([0x25, 0x50, 0x44, 0x46, 1, 2, 3]), 10), null);
});

test('the share of the budget never goes under the floor', () => {
  assert.equal(shareOf(1_000_000, 10), 100_000);
  assert.equal(shareOf(10_000, 10), 25_000);
});
