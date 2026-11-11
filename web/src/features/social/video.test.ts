import { test } from 'node:test';
import assert from 'node:assert/strict';
import { kenBurns, pickMime, slideAt, videoSeconds, wrap, VIDEO_W, VIDEO_H } from './video.ts';

test('r36b (2210): ken burns keeps the 9:16 frame inside the photo and moves', () => {
  for (const [w, h] of [[1800, 1200], [1200, 1800], [4000, 1000]] as const) {
    for (const i of [0, 1, 2, 3]) {
      for (const t of [0, 0.5, 1]) {
        const f = kenBurns(w, h, t, i);
        assert.ok(f.sx >= -1e-6 && f.sy >= -1e-6 && f.sx + f.sw <= w + 1e-6 && f.sy + f.sh <= h + 1e-6, `${w}x${h} #${i} t${t}`);
        assert.ok(Math.abs(f.sw / f.sh - VIDEO_W / VIDEO_H) < 1e-6);
      }
    }
  }
  assert.ok(kenBurns(1800, 1200, 1, 0).sw < kenBurns(1800, 1200, 0, 0).sw, 'the first photo zooms in');
  assert.ok(kenBurns(1800, 1200, 1, 1).sw > kenBurns(1800, 1200, 0, 1).sw, 'the next zooms out');
});

test('r36b (2210): slides, fades, length, type and wrapping', () => {
  assert.deepEqual(slideAt(0, 3, 2.5), { index: 0, t: 0, next: null, mix: 0 });
  const s = slideAt(2.2, 3, 2.5);
  assert.equal(s.index, 0); assert.equal(s.next, 1); assert.ok(s.mix > 0 && s.mix < 1);
  assert.equal(slideAt(7.4, 3, 2.5).next, null, 'the last photo fades into nothing');
  assert.equal(videoSeconds(8, 2.5), 20);
  assert.equal(pickMime((t) => t.startsWith('video/webm'))?.ext, 'webm');
  assert.equal(pickMime((t) => t === 'video/mp4')?.type, 'video/mp4');
  assert.equal(pickMime(() => false), null);
  assert.deepEqual(wrap('2024 Mercedes-Benz GLE 450 4MATIC Coupe', 10, (x) => x.length), ['2024', 'Mercedes-Benz…']);
  assert.deepEqual(wrap('BMW X5', 20, (x) => x.length), ['BMW X5']);
});
