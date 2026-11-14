// The windows of interior photos (0521): the cut-out's transparency read from the PNG, and the quality check that keeps
// the studio behind the windows only when the cut is clean, else (r44) keeps the photo sharp as taken: an interior is never blurred.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deflateSync } from 'node:zlib';
import { readAlpha, windowPlan, RULES } from './window-check.ts';

/** An RGBA PNG whose alpha is 0 where clear(x, y) says so; each row with a filter so every filter type is exercised. */
function png(w: number, h: number, clear: (x: number, y: number) => boolean, soft = () => false): Uint8Array {
  const raw = Buffer.alloc(h * (w * 4 + 1));
  const prev = Buffer.alloc(w * 4);
  for (let y = 0; y < h; y++) {
    const line = Buffer.alloc(w * 4);
    for (let x = 0; x < w; x++) line.set([120, 90, 60, clear(x, y) ? 0 : soft() ? 100 : 255], x * 4);
    const f = y % 5; raw[y * (w * 4 + 1)] = f;
    for (let i = 0; i < w * 4; i++) {
      const a = i >= 4 ? line[i - 4]! : 0, b = prev[i]!, c = i >= 4 ? prev[i - 4]! : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const pred = f === 0 ? 0 : f === 1 ? a : f === 2 ? b : f === 3 ? (a + b) >> 1 : pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      raw[y * (w * 4 + 1) + 1 + i] = (line[i]! - pred) & 0xff;
    }
    line.copy(prev);
  }
  const chunk = (type: string, data: Buffer) => { const l = Buffer.alloc(4); l.writeUInt32BE(data.length); return Buffer.concat([l, Buffer.from(type), data, Buffer.alloc(4)]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return new Uint8Array(Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]));
}

test('two clean side windows high in the frame: the studio goes behind them', async () => {
  const g = await readAlpha(png(240, 160, (x, y) => y < 60 && (x < 50 || x > 190)));
  const p = windowPlan(g);
  assert.equal(p.action, 'replace', JSON.stringify(p));
  assert.ok(p.metrics.clear! > RULES.minClear && p.metrics.clear! < RULES.maxClear);
});
test('no window seen: the photo is edited as before', async () => {
  assert.equal(windowPlan(await readAlpha(png(240, 160, () => false))).action, 'none');
});
test('the seat cut away low in the frame: kept sharp, with the reason', async () => {
  const p = windowPlan(await readAlpha(png(240, 160, (x, y) => y > 100 && x > 60 && x < 180)));
  assert.equal(p.action, 'none');
  assert.match(p.reasons.join(' '), /low in the frame/);
});
test('most of the frame see-through (the cabin lost, e.g. only the steering wheel kept): kept sharp, never blurred', async () => {
  assert.equal(windowPlan(await readAlpha(png(240, 160, (_x, y) => y < 120))).action, 'none');
});
test('speckled: kept sharp', async () => {
  const p = windowPlan(await readAlpha(png(480, 320, (x, y) => y < 200 && x % 40 < 15 && y % 40 < 15)));
  assert.equal(p.action, 'none', JSON.stringify(p));
});
test('a mushy edge (many half-transparent pixels): kept sharp', async () => {
  let k = 0;
  const p = windowPlan(await readAlpha(png(240, 160, (x, y) => y < 60 && x < 50, () => (k++ % 6) === 0)));
  assert.equal(p.action, 'none');
  assert.match(p.reasons.join(' '), /half-transparent/);
});
test('not a PNG (a cut-out that is a JPEG): kept sharp, never the studio', async () => {
  assert.equal(windowPlan(await readAlpha(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]))).action, 'none');
});

test('r44: no plan ever blurs an interior', async () => {
  const cases = [png(240, 160, (_x, y) => y < 150), png(240, 160, (x, y) => y > 100 && x > 60), png(240, 160, () => true), new Uint8Array([1, 2, 3])];
  for (const c of cases) assert.notEqual(windowPlan(await readAlpha(c)).action, 'blur');
});
