import { test } from 'node:test';
import assert from 'node:assert/strict';
import { captureInstant, captureTime } from './exif.ts';
import { cleanPlate, groupByTime, retryDelay, uploadKey } from './group.ts';

// a TIFF block with IFD0 (one tag: the Exif pointer) and an Exif IFD (DateTimeOriginal, and OffsetTimeOriginal when given)
function exifBlock(date: string, offset: string | null, le: boolean, prefix: number[] = [0xff, 0xd8, 0xff, 0xe1, 0, 0]): Uint8Array {
  const out: number[] = [];
  const u16 = (v: number) => (le ? [v & 255, v >> 8] : [v >> 8, v & 255]);
  const u32 = (v: number) => (le ? [v & 255, (v >> 8) & 255, (v >> 16) & 255, v >>> 24] : [v >>> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255]);
  const n = offset ? 2 : 1;
  const exifIfd = 8 + 2 + 12 + 4;
  const dataAt = exifIfd + 2 + n * 12 + 4;
  out.push(...(le ? [0x49, 0x49, 0x2a, 0] : [0x4d, 0x4d, 0, 0x2a]), ...u32(8));
  out.push(...u16(1), ...u16(0x8769), ...u16(4), ...u32(1), ...u32(exifIfd), ...u32(0));
  out.push(...u16(n), ...u16(0x9003), ...u16(2), ...u32(20), ...u32(dataAt));
  if (offset) out.push(...u16(0x9011), ...u16(2), ...u32(7), ...u32(dataAt + 20));
  out.push(...u32(0));
  out.push(...[...date].map((c) => c.charCodeAt(0)), 0);
  if (offset) out.push(...[...offset].map((c) => c.charCodeAt(0)), 0);
  return Uint8Array.from([...prefix, 0x45, 0x78, 0x69, 0x66, 0, 0, ...out, 1, 2, 3]);
}

test('capture time: a JPEG (little endian) with no zone is a Toronto wall clock', () => {
  const c = captureTime(exifBlock('2026:11:20 14:03:09', null, true));
  assert.deepEqual(c, { local: '2026-11-20T14:03:09', offset: null });
  assert.equal(captureInstant(c!), '2026-11-20T19:03:09.000Z'); // EST
  assert.equal(captureInstant({ local: '2026-07-01T09:00:00', offset: null }), '2026-07-01T13:00:00.000Z'); // EDT
});
test('capture time: a HEIC (big endian, the block deep in the file) with the phone\'s zone', () => {
  const c = captureTime(exifBlock('2026:10:02 08:15:00', '-04:00', false, Array.from({ length: 3000 }, (_, i) => (i * 7) & 0x3f)));
  assert.deepEqual(c, { local: '2026-10-02T08:15:00', offset: '-04:00' });
  assert.equal(captureInstant(c!), '2026-10-02T12:15:00.000Z');
});
test('capture time: none in a photo with no tags, or a blank date', () => {
  assert.equal(captureTime(Uint8Array.from([0xff, 0xd8, 0xff, 0xdb, 1, 2, 3])), null);
  assert.equal(captureTime(exifBlock('0000:00:00 00:00:00', null, true)), null);
});

test('groups: photos within the gap are one group, a long pause starts the next, no time is its own group', () => {
  const g = groupByTime([
    { id: 'c', at: '2026-11-20T15:40:00Z' }, { id: 'a', at: '2026-11-20T15:00:00Z' }, { id: 'b', at: '2026-11-20T15:20:00Z' },
    { id: 'd', at: '2026-11-21T09:00:00Z' }, { id: 'x', at: null }], 30);
  assert.deepEqual(g.map((x) => x.items.map((i) => i.id).join('')), ['abc', 'd', 'x']);
  assert.deepEqual([g[0]!.from, g[0]!.to], ['2026-11-20T15:00:00Z', '2026-11-20T15:40:00Z']);
  assert.deepEqual(g.map((x) => x.i), [0, 1, 2]);
});
test('plates: only letters and digits, 2 to 8 of them', () => {
  assert.equal(cleanPlate('cbxa 123'), 'CBXA123');
  assert.equal(cleanPlate(null), null);
  assert.equal(cleanPlate('A'), null);
  assert.equal(cleanPlate('ABCDEFGHIJ'), null);
});
test('retries wait longer each time, at most 30 seconds', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 9].map(retryDelay), [2000, 2000, 4000, 8000, 16000, 30000, 30000]);
});
test('upload key: the same photo gets the same key (picked again it is attached once), another photo another key', async () => {
  const a = await uploadKey(Uint8Array.from([0xff, 0xd8, 1, 2, 3]).buffer);
  assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  assert.equal(await uploadKey(Uint8Array.from([0xff, 0xd8, 1, 2, 3]).buffer), a);
  assert.notEqual(await uploadKey(Uint8Array.from([0xff, 0xd8, 1, 2, 4]).buffer), a);
});
