// Unit tests for the plates of a listing photo (r35 S2): the perspective map, the corners found, the CARMA plate drawn in
// perspective, the front plate edited out, and no real plate text left.
//   node --test --experimental-strip-types src/features/listing/plate-photo.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyPlates, boxQuad, drawPlate, homography, lookAround, mapPt, plateEnd, plateQuad, removePlate, type Quad } from './plate-photo.ts';
import { PLATE_TEXT, plateRgba, plateSvg } from './plate-art.ts';
import type { Rgba } from './subject-frame.ts';

const W = 400, H = 260;
/** A bumper (a soft grey gradient) with a real-looking plate on it: white, black characters, its corners `q`. */
function photo(q: Quad): Rgba {
  const data = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const i = (y * W + x) * 4, v = 90 + 30 * (y / H) + 8 * Math.sin(x / 40); data[i] = v; data[i + 1] = v + 2; data[i + 2] = v + 6; data[i + 3] = 255; }
  const inv = homography(q, [[0, 0], [1, 0], [1, 1], [0, 1]])!;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const [u, v] = mapPt(inv, [x + 0.5, y + 0.5]);
    if (u < 0 || u > 1 || v < 0 || v > 1) continue;
    // characters: six dark bars across the middle (the plate's letters)
    const ink = v > 0.3 && v < 0.75 && u > 0.08 && u < 0.92 && Math.floor((u - 0.08) * 14) % 2 === 0;
    const i = (y * W + x) * 4, c = ink ? 25 : 235;
    data[i] = c; data[i + 1] = c; data[i + 2] = c;
  }
  return { width: W, height: H, data };
}
const inQuadBox = (img: Rgba, x0: number, y0: number, x1: number, y1: number, f: (r: number, g: number, b: number) => boolean) => {
  let n = 0; for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const i = (y * img.width + x) * 4; if (f(img.data[i]!, img.data[i + 1]!, img.data[i + 2]!)) n++; } return n;
};

test('the perspective map takes each corner to its corner', () => {
  const q: Quad = [[120, 100], [290, 112], [286, 190], [118, 172]];
  const h = homography([[0, 0], [600, 0], [600, 300], [0, 300]], q)!;
  for (const [i, p] of ([[0, 0], [600, 0], [600, 300], [0, 300]] as const).entries()) {
    const m = mapPt(h, [p[0], p[1]]);
    assert.ok(Math.abs(m[0] - q[i]![0]) < 1e-6 && Math.abs(m[1] - q[i]![1]) < 1e-6, `corner ${i}`);
  }
  assert.equal(homography([[0, 0], [1, 0], [2, 0], [3, 0]], q), null, 'degenerate');
  assert.equal(plateEnd('front_left'), 'front');
  assert.equal(plateEnd('rear_right'), 'rear');
});

test('the plate seen at an angle: its slanted corners are found from its box', () => {
  const q: Quad = [[130, 100], [270, 116], [268, 186], [128, 166]];
  const img = photo(q);
  const box = { x: 124, y: 96, w: 152, h: 94 };
  const found = plateQuad(img, box);
  for (let i = 0; i < 4; i++) assert.ok(Math.hypot(found[i]![0] - q[i]![0], found[i]![1] - q[i]![1]) < 9, `corner ${i}: ${found[i]} vs ${q[i]}`);
  // a box over a plain bumper: its own corners
  assert.deepEqual(plateQuad(photo([[0, 0], [1, 0], [1, 1], [0, 1]]), { x: 20, y: 20, w: 60, h: 30 }), boxQuad({ x: 20, y: 20, w: 60, h: 30 }));
});

test('the rear plate becomes the CARMA plate in perspective, matched to the photo, and no real plate text is left', () => {
  const q: Quad = [[130, 100], [270, 116], [268, 186], [128, 166]];
  const img = photo(q), before = new Uint8ClampedArray(img.data);
  applyPlates(img, [{ x: 124, y: 96, w: 152, h: 94 }], 'rear');
  const blue = inQuadBox(img, 130, 100, 270, 186, (r, g, b) => b > r + 40 && b > g + 25);
  assert.ok(blue > 600, `CARMA in Ontario blue (${blue} px)`);
  const dark = inQuadBox(img, 135, 125, 265, 160, (r, g, b) => r < 60 && g < 60 && b < 60);
  assert.ok(dark < 40, `the real plate's characters are gone (${dark} dark px)`);
  // lit as the photo: the plate's white is no brighter than the photo's light allows
  const white = inQuadBox(img, 135, 105, 265, 180, (r, g, b) => r > 252 && g > 252 && b > 252);
  assert.ok(white < 30, 'not pasted at full white');
  let same = 0; for (let i = 0; i < before.length; i += 4) { const y = Math.floor(i / 4 / W); if (y < 60 && before[i] === img.data[i]) same++; }
  assert.equal(same, W * 60, 'nothing outside the plate changes');
});

test('the front plate is edited out: no box, no characters, the bumper continues', () => {
  const q: Quad = [[140, 110], [260, 110], [260, 170], [140, 170]];
  const img = photo(q);
  removePlate(img, { x: 136, y: 106, w: 128, h: 68 });
  const lums: number[] = [];
  for (let y = 112; y < 168; y += 2) for (let x = 142; x < 258; x += 2) { const i = (y * W + x) * 4; lums.push((img.data[i]! + img.data[i + 1]! + img.data[i + 2]!) / 3); }
  const mean = lums.reduce((a, b) => a + b, 0) / lums.length, sd = Math.sqrt(lums.reduce((a, b) => a + (b - mean) ** 2, 0) / lums.length);
  assert.ok(Math.abs(mean - 107) < 15, `the bumper's grey (${mean.toFixed(1)})`);
  assert.ok(sd < 12, `smooth, no characters (${sd.toFixed(1)})`);
  assert.equal(inQuadBox(img, 140, 110, 260, 170, (r) => r > 200 || r < 50), 0, 'no white plate, no black characters');
});

test('the CARMA plate: Ontario, the company plate, blue on white, drawn without a font', () => {
  const svg = plateSvg();
  assert.match(svg, /viewBox="0 0 600 300"/);
  assert.match(svg, /fill="rgb\(18,58,140\)"/);
  assert.equal(PLATE_TEXT, 'CARMA');
  const p = plateRgba(300);
  assert.deepEqual([p.width, p.height], [300, 150]);
  assert.equal(p.data[3], 0, 'rounded corner clear');
  const i = (75 * 300 + 150) * 4;
  assert.ok(p.data[i + 3] === 255);
  // drawing on a flat quad keeps the plate's proportions and look
  const img: Rgba = { width: 200, height: 120, data: new Uint8ClampedArray(200 * 120 * 4).fill(120) };
  drawPlate(img, boxQuad({ x: 20, y: 20, w: 160, h: 80 }), lookAround(img, { x: 20, y: 20, w: 160, h: 80 }));
  assert.ok(inQuadBox(img, 20, 20, 180, 100, (r, g, b) => b > r + 40) > 300);
});

test('the worker makes a covered photo again: the plate blurred (r45, nothing drawn), the sizes, never the real characters', async () => {
  const { runJob } = await import('./worker.ts');
  const { encodeJpeg, decodeImage } = await import('./showroom.ts');
  const { fakeText } = await import('../../integrations/llm/fake.ts');
  const { fakePhotos } = await import('../../integrations/photos/fake.ts');
  const q: Quad = [[130, 100], [270, 116], [268, 186], [128, 166]];
  const priv = new Map<string, Uint8Array>([['vehicles/v1/uncovered/rear.jpg', encodeJpeg(photo(q), 95)]]);
  const pub = new Map<string, Uint8Array>();
  const deps = { claim: async () => ({ jobs: [], budget: { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 }, held: { photos: false, copy: false }, due: 0 }),
    report: async () => ({}), decodeVin: async () => ({ provider: 'fake', result: { ok: true } }), text: fakeText(), photos: fakePhotos(async () => null),
    files: { privateUrl: async (p: string) => p, publicUrl: (p: string) => p, getPrivate: async (p: string) => priv.get(p) ?? null, putPrivate: async () => undefined, putPublic: async (p: string, b: Uint8Array) => { pub.set(p, b); } } };
  const r = await runJob(deps, { id: 'abcdef12-0000', kind: 'plate_redo', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4,
    input: { plate: { photo_id: 'p1', vehicle_id: 'v1', source: 'vehicles/v1/uncovered/rear.jpg', prev_path: 'vehicles/v1/car-rear-cabc123.jpg', boxes: [{ x: 124 / W, y: 96 / H, w: 152 / W, h: 94 / H }], end: 'rear', widths: [200] } } },
    { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 });
  const o = (r.output as { plate: { processed_path: string; variants: Array<{ width: number; path: string }> } }).plate;
  assert.equal(r.ok, true);
  assert.match(o.processed_path, /^vehicles\/v1\/car-rear-pabcdef\.jpg$/);
  assert.deepEqual(o.variants.map((v) => v.width), [200]);
  const out = (await decodeImage(pub.get(o.processed_path)!))!;
  assert.ok(inQuadBox(out, 130, 100, 270, 186, (r2, g, b) => b > r2 + 40) < 40, 'no CARMA plate drawn');
  assert.ok(inQuadBox(out, 135, 125, 265, 160, (r2, g, b) => r2 < 60 && g < 60 && b < 60) < 40, 'no real characters');
});
