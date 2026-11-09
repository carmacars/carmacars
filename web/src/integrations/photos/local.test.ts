// Unit tests for the local photo steps (release 35, 1050): every step but the cut-out made here, Cloudflare only where needed.
//   node --test --experimental-strip-types src/integrations/photos/local.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { coverFit, hybridPhotos, localImages, resample, scaleDown, tone } from './local.ts';
import { decodeImage, encodeJpeg } from '../../features/listing/showroom.ts';
import { encodePng, type Rgba } from '../../features/listing/subject-frame.ts';
import type { PhotoOut, PhotoProcessor } from './types.ts';

const solid = (w: number, h: number, rgba: [number, number, number, number]): Rgba => {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < data.length; i += 4) data.set(rgba, i);
  return { width: w, height: h, data };
};

test('resample: one pass down averages the area (no aliasing), sizes are exact', () => {
  // a 1-pixel checkerboard averages to grey going down 4x
  const w = 64, h = 64, data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const v = (x + y) % 2 ? 255 : 0; data.set([v, v, v, 255], (y * w + x) * 4); }
  const r = resample({ width: w, height: h, data }, { x: 0, y: 0, w, h }, 16, 16);
  assert.deepEqual([r.width, r.height], [16, 16]);
  for (let i = 0; i < r.data.length; i += 4) assert.ok(Math.abs(r.data[i]! - 128) < 3, `grey, not stripes (${r.data[i]})`);
  // clear pixels do not darken the edge of an opaque one (premultiplied)
  const edge = { width: 2, height: 1, data: new Uint8ClampedArray([255, 255, 255, 255, 0, 0, 0, 0]) };
  const e = resample(edge, { x: 0, y: 0, w: 2, h: 1 }, 1, 1);
  assert.deepEqual([e.data[0], e.data[3]], [255, 128]);
});

test('coverFit crops to the aspect around the centre (after a trim); scaleDown never grows', () => {
  const img = solid(400, 100, [10, 20, 30, 255]);
  for (let y = 0; y < 100; y++) for (let x = 150; x < 250; x++) img.data.set([250, 0, 0, 255], (y * 400 + x) * 4);
  const c = coverFit(img, 120, 120);
  assert.deepEqual([c.width, c.height], [120, 120]);
  assert.ok(c.data[(60 * 120 + 60) * 4]! > 240, 'the middle kept');
  const t = coverFit(img, 100, 100, { top: 0, right: 0, bottom: 0, left: 300 });
  assert.ok(t.data[(50 * 100 + 50) * 4]! < 20, 'a trim moves the centre');
  assert.equal(scaleDown(img, 800), img);
  assert.deepEqual([scaleDown(img, 200).width, scaleDown(img, 200).height], [200, 50]);
  const toned = tone(solid(2, 2, [100, 100, 100, 255]), { brightness: 1.2 });
  assert.ok(toned.data[0]! > 100 && toned.data[3] === 255);
});

test('the local processor: sizes, interiors and the studio drawn here, no transformation counted', async () => {
  const files = new Map<string, Uint8Array>();
  files.set('src', encodeJpeg(solid(1200, 900, [90, 90, 90, 255]), 90));
  files.set('bg', await encodePng(solid(1800, 1200, [0, 0, 0, 255])));
  files.set('car', await encodePng(solid(600, 250, [200, 30, 30, 255])));
  const p = localImages(async (u) => files.get(u) ?? null);
  const r = await p.resize({ sourceUrl: 'src', width: 480 }) as Extract<PhotoOut, { ok: true }>;
  assert.ok(r.ok && r.transformations === 0 && r.contentType === 'image/jpeg');
  assert.deepEqual([(await decodeImage(r.bytes))!.width, (await decodeImage(r.bytes))!.height], [480, 360]);
  const n = await p.normalize({ sourceUrl: 'src', width: 1600, height: 1200 }) as Extract<PhotoOut, { ok: true }>;
  assert.deepEqual([(await decodeImage(n.bytes))!.width, (await decodeImage(n.bytes))!.height], [1600, 1200]);
  const c = await p.composite({ backdropUrl: 'bg', shadowUrl: 'none', cutoutUrl: 'car', width: 1800, height: 1200, place: { width: 1200, height: 500, left: 300, bottom: 200 } }) as Extract<PhotoOut, { ok: true }>;
  const img = (await decodeImage(c.bytes))!;
  const at = (x: number, y: number) => img.data[(y * 1800 + x) * 4]!;
  assert.ok(at(900, 750) > 150 && at(100, 100) < 20, 'the car drawn where placed, the backdrop around it');
  const missing = await p.resize({ sourceUrl: 'nope', width: 480 });
  assert.ok(!missing.ok && missing.retryable);
  const cut = await p.cutout('src');
  assert.ok(!cut.ok && cut.reason === 'not_enabled', 'the cut-out is never local');
});

test('hybrid: Cloudflare only for the cut-out unless asked for everything; a quota falls back to local', async () => {
  const calls: string[] = [];
  const ok = (bytes: number): PhotoOut => ({ ok: true, bytes: new Uint8Array([bytes]), contentType: 'image/jpeg', transformations: 1 });
  const cf: PhotoProcessor = { name: 'cloudflare-images',
    cutout: async () => { calls.push('cf:cutout'); return ok(1); },
    composite: async () => { calls.push('cf:composite'); return ok(2); },
    normalize: async () => { calls.push('cf:normalize'); return { ok: false, reason: 'quota', retryable: true, message: 'rate limited' }; },
    layer: async () => ok(3), resize: async () => { calls.push('cf:resize'); return ok(4); },
    toJpeg: async () => { calls.push('cf:toJpeg'); return ok(5); } };
  const local: PhotoProcessor = { name: 'local',
    cutout: async () => ({ ok: false, reason: 'not_enabled', retryable: false, message: 'x' }),
    composite: async () => { calls.push('local:composite'); return ok(12); },
    normalize: async () => { calls.push('local:normalize'); return ok(13); },
    layer: async () => ok(14), resize: async () => { calls.push('local:resize'); return ok(15); },
    toJpeg: async () => { calls.push('local:toJpeg'); return { ok: false, reason: 'not_enabled', retryable: false, message: 'heic' }; } };
  const off = hybridPhotos(local, cf, false);
  await off.cutout('u'); await off.resize({ sourceUrl: 'u', width: 480 }); await off.composite({ backdropUrl: 'b', shadowUrl: 's', cutoutUrl: 'c', width: 1, height: 1 });
  await off.toJpeg!({ sourceUrl: 'u', width: 10 });
  assert.deepEqual(calls, ['cf:cutout', 'local:resize', 'local:composite', 'local:toJpeg', 'cf:toJpeg'], 'off: only the cut-out and a HEIC go to Cloudflare');
  assert.equal(off.name, 'local');
  calls.length = 0;
  const on = hybridPhotos(local, cf, true);
  await on.resize({ sourceUrl: 'u', width: 480 });
  const n = await on.normalize({ sourceUrl: 'u', width: 1, height: 1 });
  assert.deepEqual(calls, ['cf:resize', 'cf:normalize', 'local:normalize'], 'on: Cloudflare first, a quota falls back to local');
  assert.ok(n.ok && n.bytes[0] === 13);
});
