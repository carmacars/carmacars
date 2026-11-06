import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ENHANCE_LIMITS, enhanceValues, statsOf, type Pixels } from './enhance.ts';

/** A photo of n pixels whose luminance runs evenly from lo to hi (grey, or tinted with the given saturation). */
function ramp(lo: number, hi: number, o: { sat?: number; alphaShare?: number; n?: number } = {}): Pixels {
  const n = o.n ?? 10_000, data = new Uint8ClampedArray(n * 4);
  for (let i = 0; i < n; i++) {
    const v = Math.round((lo + ((hi - lo) * i) / (n - 1)) * 255), s = o.sat ?? 0;
    data[i * 4] = v; data[i * 4 + 1] = Math.round(v * (1 - s)); data[i * 4 + 2] = Math.round(v * (1 - s));
    data[i * 4 + 3] = i < n * (o.alphaShare ?? 1) ? 255 : 0;
  }
  return { width: n, height: 1, data };
}
const within = (e: NonNullable<ReturnType<typeof enhanceValues>>) => {
  for (const k of ['brightness', 'contrast', 'gamma', 'saturation', 'sharpen'] as const) {
    const [lo, hi] = ENHANCE_LIMITS[k]; assert.ok(e[k] >= lo && e[k] <= hi, `${k} ${e[k]} within ${lo} to ${hi}`);
  }
};

test('the measures come from the photo\'s own histogram, the clear part of a cut-out left out', () => {
  const s = statsOf(ramp(0.1, 0.9, { alphaShare: 0.5 }), 200);
  assert.equal(s.n, 5000);
  assert.ok(Math.abs(s.p50 - 0.3) < 0.01 && Math.abs(s.p99 - 0.5) < 0.01, JSON.stringify(s));
});

test('a dull, flat, dark interior gets the most help; still a subtle touch-up', () => {
  const e = enhanceValues(statsOf(ramp(0.15, 0.6), 1))!;
  within(e);
  assert.ok(e.brightness > 1 && e.gamma > 1 && e.contrast > 1.05 && e.saturation === 1.08, JSON.stringify(e));
});

test('a well exposed, colourful photo is barely touched; blown highlights are pulled back', () => {
  const e = enhanceValues(statsOf(ramp(0.02, 0.99), 1))!;
  within(e);
  assert.deepEqual([e.brightness, e.contrast], [1, 1.03]);
  const colourful = enhanceValues(statsOf(ramp(0.05, 1, { sat: 0.6 }), 1))!;
  assert.ok(colourful.saturation <= 1.03 + 1e-9, `a colourful photo gains at most 3% (${colourful.saturation})`);
  const white = ramp(0.3, 1.1);   // the top 9% at full white
  const blown = enhanceValues(statsOf(white, 1))!;
  assert.equal(blown.brightness, 0.98);
});

test('a black car outside is not lifted to grey: its paint sets the median, so only a small move is made', () => {
  const black = statsOf(ramp(0.02, 0.5), 1);
  const outside = enhanceValues(black, { exterior: true })!, inside = enhanceValues(black)!;
  assert.ok(outside.gamma < inside.gamma && outside.gamma <= 1.04, JSON.stringify(outside));
  within(outside);
});

test('never a colour shift, never smoothing; too little to measure keeps the photo as it is', () => {
  const e = enhanceValues(statsOf(ramp(0.1, 0.9), 1))!;
  assert.deepEqual(Object.keys(e).sort(), ['brightness', 'contrast', 'gamma', 'saturation', 'sharpen', 'version']);
  assert.ok(e.saturation >= 1 && e.sharpen > 0);
  assert.equal(enhanceValues(statsOf(ramp(0.1, 0.9, { n: 100 }), 1)), null);
});
