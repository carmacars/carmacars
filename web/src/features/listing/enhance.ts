// A light automatic touch-up on every listing photo (release 28, B9; migration 0568; Admin > Settings > Listings
// "Auto-enhance listing photos", on by default; a photo's "Use original colours" in the listing review turns it off for
// that photo). The worker measures the photo (an outside photo: the car's own pixels from the framed cut-out; any other:
// a small PNG preview) and works out the values here; Cloudflare applies them (brightness, contrast, gamma, saturation,
// sharpen) on top of the studio or the normalized photo. The values are kept on the photo (vehicle_photos.enhance).
//
// Honest by design: every value is clamped close to "no change" (the edit must not stand out), there is no hue or
// per-channel shift (Cloudflare has none, and a white balance worked out from a car's own pixels would move its paint
// colour), saturation rises at most 8% and less on an already colourful photo, and nothing blurs or smooths (a scratch
// or wear stays as visible as it was). Pure; unit tested in enhance.test.ts.

export interface Pixels { width: number; height: number; data: Uint8ClampedArray }
export interface PhotoStats {
  /** pixels counted */
  n: number;
  /** luminance (0 to 1) at the 1st, 50th and 99th percentiles */
  p1: number; p50: number; p99: number;
  /** share of the pixels at full white (blown highlights) */
  clipped: number;
  /** mean saturation (0 to 1) */
  sat: number;
}
export interface Enhance { version: 'enhance_v1'; brightness: number; contrast: number; gamma: number; saturation: number; sharpen: number }

export const ENHANCE_LIMITS = {
  brightness: [0.97, 1.06], contrast: [1.03, 1.08], gamma: [0.95, 1.08], saturation: [1.0, 1.08], sharpen: [0.5, 1.0]
} as const;
const clamp = (v: number, [lo, hi]: readonly [number, number]) => Math.min(hi, Math.max(lo, v));
const r3 = (v: number) => Math.round(v * 1000) / 1000;

/** The photo's measures; pixels under minAlpha (the clear part of a cut-out, its shadow) are left out. */
export function statsOf(img: Pixels, minAlpha = 200): PhotoStats {
  const hist = new Uint32Array(256);
  let n = 0, satSum = 0, white = 0;
  const d = img.data;
  for (let i = 0; i < d.length; i += 4) {
    if (d[i + 3]! < minAlpha) continue;
    const r = d[i]!, g = d[i + 1]!, b = d[i + 2]!;
    const y = Math.round(0.2126 * r + 0.7152 * g + 0.0722 * b);
    hist[y]!++; n++;
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
    satSum += mx ? (mx - mn) / mx : 0;
    if (mx >= 254 && mn >= 250) white++;
  }
  const at = (q: number) => { const want = q * n; let c = 0; for (let v = 0; v < 256; v++) { c += hist[v]!; if (c >= want) return v / 255; } return 1; };
  return { n, p1: n ? at(0.01) : 0, p50: n ? at(0.5) : 0, p99: n ? at(0.99) : 1, clipped: n ? white / n : 0, sat: n ? satSum / n : 0 };
}

/** The touch-up for a photo from its measures; null when there is too little to measure (the photo is kept as it is). */
export function enhanceValues(s: PhotoStats, o: { exterior?: boolean } = {}): Enhance | null {
  if (s.n < 500 || s.p99 <= s.p1) return null;
  // levels from the photo's own histogram: highlights lifted toward white when they fall short, pulled back a touch when blown
  const brightness = s.clipped > 0.02 ? 0.98 : s.p99 < 0.93 ? 0.96 / Math.max(s.p99, 0.5) : 1;
  // exposure: the midtones moved a little toward a natural middle; on an outside photo the car's paint sets the median
  // (a black car is dark, not underexposed), so only a third of the move is made there
  const target = 0.45, pull = o.exterior ? 0.2 : 0.6;
  const gamma = 1 + (target - s.p50) * pull;
  // contrast: a flat photo (a narrow range) gets more, a punchy one the minimum small boost
  const contrast = 1 + Math.max(0, 0.9 - (s.p99 - s.p1)) * 0.2 + 0.03;
  // saturation: +8% for a dull photo, +3% for a colourful one, never more
  const saturation = 1 + 0.08 - Math.min(0.05, Math.max(0, s.sat - 0.25) * 0.2);
  // mild sharpening, halved on a dark photo (its noise would be sharpened too)
  const sharpen = s.p50 < 0.22 ? 0.5 : 1;
  return {
    version: 'enhance_v1',
    brightness: r3(clamp(brightness, ENHANCE_LIMITS.brightness)), contrast: r3(clamp(contrast, ENHANCE_LIMITS.contrast)),
    gamma: r3(clamp(gamma, ENHANCE_LIMITS.gamma)), saturation: r3(clamp(saturation, ENHANCE_LIMITS.saturation)),
    sharpen: r3(clamp(sharpen, ENHANCE_LIMITS.sharpen))
  };
}
