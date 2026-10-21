// Builds the listing photo presets (docs/blueprint/09-listing-pipeline.md section 5.4), versioned in the
// repository: the CarmaCars studio backdrop brand_background_v1 (a light grey floor fading to white, the
// horizon at the same height in every photo) and the soft ground shadow placed under the car.
//   node scripts/gen-backdrop.mjs     writes src/features/listing/presets/{brand_background_v1,shadow_v1}.png
// Node built-ins only (zlib for the PNG data). The deploy uploads both to the public photo bucket under
// site/backdrop/ once (scripts/deploy, photos).
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'features', 'listing', 'presets');
const CRC = new Uint32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = (b) => { let c = 0xffffffff; for (const x of b) c = CRC[(c ^ x) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0); out.write(type, 4, 'ascii'); data.copy(out, 8);
  out.writeUInt32BE(crc(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}
function png(w, h, channels, pixel) {
  const row = w * channels + 1;
  const raw = Buffer.alloc(row * h);
  for (let y = 0; y < h; y++) { raw[y * row] = 0; for (let x = 0; x < w; x++) { const p = pixel(x, y); for (let c = 0; c < channels; c++) raw[y * row + 1 + x * channels + c] = p[c]; } }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = channels === 4 ? 6 : 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}
const mix = (a, b, t) => Math.round(a + (b - a) * Math.min(1, Math.max(0, t)));

// 2400 x 1600 (3:2): white wall, a soft horizon at 62%, the floor darkening gently toward the camera
const W = 2400, H = 1600, HORIZON = 0.62;
writeFileSync(join(OUT, 'brand_background_v1.png'), png(W, H, 3, (x, y) => {
  const t = y / H;
  let v;
  if (t < HORIZON - 0.04) v = mix(252, 246, t / (HORIZON - 0.04));
  else if (t < HORIZON + 0.04) v = mix(246, 236, (t - (HORIZON - 0.04)) / 0.08);
  else v = mix(236, 214, (t - (HORIZON + 0.04)) / (1 - HORIZON - 0.04));
  const vignette = 1 - 0.035 * Math.pow(Math.abs(x / W - 0.5) * 2, 2);
  v = Math.round(v * vignette);
  return [v, v, v];
}));

// 1600 x 220 soft elliptical shadow, black with alpha, darkest at the centre line
const SW = 1600, SH = 220;
writeFileSync(join(OUT, 'shadow_v1.png'), png(SW, SH, 4, (x, y) => {
  const dx = (x - SW / 2) / (SW / 2), dy = (y - SH * 0.55) / (SH / 2);
  const d = Math.sqrt(dx * dx * 0.92 + dy * dy * 1.6);
  const a = d >= 1 ? 0 : Math.round(150 * Math.pow(1 - d, 1.8));
  return [20, 20, 20, a];
}));

// 1800 x 1200 studio_v2 (migration 0073): the sample cars' studio (src/features/car/studio.ts) as pixels, so real photos
// sit in the same black room: the overhead spot, the floor line at 74%, the floor fading to black, the pool of light.
// The model's name is drawn over it per car (src/features/listing/lettering.ts).
{
  const W2 = 1800, H2 = 1200, FY = H2 * 0.74;
  const lerp = (stops, t) => {
    t = Math.min(1, Math.max(0, t));
    for (let i = 1; i < stops.length; i++) if (t <= stops[i][0]) { const [a, ca] = stops[i - 1], [b, cb] = stops[i]; const k = (t - a) / (b - a || 1); return ca.map((c, j) => c + (cb[j] - c) * k); }
    return stops[stops.length - 1][1];
  };
  const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const SPOT = [[0, hex('#6b6b6b')], [0.35, hex('#2a2a2a')], [0.75, hex('#0b0b0b')], [1, hex('#000000')]];
  const POOL = [[0, [0.22]], [0.6, [0.05]], [1, [0]]];
  writeFileSync(join(OUT, 'studio_v2.png'), png(W2, H2, 3, (x, y) => {
    const px = x + 0.5, py = y + 0.5;
    let c;
    if (py < FY) c = lerp(SPOT, Math.hypot((px - W2 * 0.5) / (0.95 * W2), (py - 0.08 * FY) / (0.95 * FY)));
    else { const t = (py - FY) / (H2 - FY); c = [0x16, 0x16, 0x16].map((v) => v * (1 - t)); }
    // the pool of light on the floor
    const rx = W2 * 0.52, ry = (H2 - FY) * 0.5, cy = FY + (H2 - FY) * 0.22;
    const pd = Math.hypot((px - W2 * 0.5) / rx, (py - cy) / ry);
    const pa = pd < 1 ? lerp(POOL, pd)[0] : 0;
    c = c.map((v) => v + (255 - v) * pa);
    // the floor line
    if (py >= FY - 1 && py < FY + 1) c = c.map((v) => v + (255 - v) * 0.1);
    return c.map((v) => Math.round(v));
  }));
}
console.log('presets written to', OUT);
