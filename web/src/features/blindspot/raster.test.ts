// The Blind Spot agreement as a picture (r28 A11, migration 0544): the filled stand-in is rasterized (poppler's pdftoppm,
// skipped where it is not installed) and compared with the same form with nothing typed in. Every value must leave ink
// inside its own box, and no ink may land anywhere else: the field positions are checked on the rendered page, not only
// in the layout numbers.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { layout, type Layout, type Text } from './layout.ts';
import { fillBlindSpot } from './fill.ts';
import { sampleFacts } from './sample.ts';
import { standIn } from './stand-in.ts';

const MAILING = { line: '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2', street: '2967 Dundas St W', unit: '208B', city: 'Toronto', province: 'ON', postal_code: 'M6P 1Z2' };
const DPI = 144; const K = DPI / 72;
const hasPoppler = (() => { try { execFileSync('pdftoppm', ['-v'], { stdio: 'ignore' }); return true; } catch { return false; } })();

/** Page 1 as 8-bit grey pixels. */
function raster(pdf: Uint8Array): { w: number; h: number; px: Uint8Array } {
  const dir = mkdtempSync(join(tmpdir(), 'bs-raster-'));
  try {
    writeFileSync(join(dir, 'f.pdf'), pdf);
    execFileSync('pdftoppm', ['-gray', '-r', String(DPI), '-f', '1', '-l', '1', '-singlefile', join(dir, 'f.pdf'), join(dir, 'p')]);
    const b = readFileSync(join(dir, 'p.pgm'));
    // P5 <w> <h> <max>\n<pixels>
    const head = b.subarray(0, 64).toString('latin1').match(/^P5\s+(\d+)\s+(\d+)\s+(\d+)\s/);
    assert.ok(head, 'a PGM image');
    const [w, h] = [Number(head[1]), Number(head[2])];
    return { w, h, px: new Uint8Array(b.subarray(head[0].length, head[0].length + w * h)) };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
/** Where a value's ink may be, in points from the top left: its box width from where it is anchored, a line high. */
function area(t: Text, pad = 2) {
  const x0 = t.align === 'right' ? t.x - t.w : t.align === 'center' ? t.x - t.w / 2 : t.x;
  return { x0: x0 - pad, x1: x0 + t.w + pad, y0: t.y - t.size - pad, y1: t.y + t.size * 0.35 + pad };
}

test('the filled agreement, rasterized: every value inks its own box and nothing lands anywhere else', { skip: hasPoppler ? false : 'pdftoppm (poppler) is not installed' }, async () => {
  const f = sampleFacts({ mailing: MAILING, hst_number: '123456789RT0001' });
  f.extra.late_fee_cents = 2500;
  f.extra.readings = { odometer_out_km: 41000, fuel_out_pct: 100, odometer_in_km: 41500, fuel_in_pct: 75 };
  const l = layout(f);
  assert.ok(l.texts.length > 30, 'a full agreement');
  const empty: Layout = { texts: [], dots: [], covers: l.covers };
  const tpl = await standIn();
  const a = raster((await fillBlindSpot(tpl, l, {})).bytes);
  const b = raster((await fillBlindSpot(tpl, empty, {})).bytes);
  assert.equal(a.w, b.w); assert.equal(a.h, b.h);
  const diff = (x: number, y: number) => Math.abs(a.px[y * a.w + x]! - b.px[y * b.w + x]!) > 48;
  const inkIn = (r: { x0: number; x1: number; y0: number; y1: number }) => {
    let n = 0;
    for (let y = Math.max(0, Math.floor(r.y0 * K)); y < Math.min(a.h, Math.ceil(r.y1 * K)); y++)
      for (let x = Math.max(0, Math.floor(r.x0 * K)); x < Math.min(a.w, Math.ceil(r.x1 * K)); x++) if (diff(x, y)) n++;
    return n;
  };
  const missing = l.texts.filter((t) => inkIn(area(t)) === 0).map((t) => t.box);
  assert.deepEqual(missing, [], 'each value shows on the page inside its box');
  // no ink outside the boxes (the dots have their own small circles)
  const allowed = [...l.texts.map((t) => area(t)), ...l.dots.map((d) => ({ x0: d.x - d.r - 2, x1: d.x + d.r + 2, y0: d.y - d.r - 2, y1: d.y + d.r + 2 }))];
  let stray = 0; let first = '';
  for (let y = 0; y < a.h; y++) for (let x = 0; x < a.w; x++) {
    if (!diff(x, y)) continue;
    const px = x / K; const py = y / K;
    if (!allowed.some((r) => px >= r.x0 && px <= r.x1 && py >= r.y0 && py <= r.y1)) { stray++; if (!first) first = `${px.toFixed(0)},${py.toFixed(0)}`; }
  }
  assert.equal(stray, 0, `ink outside every box (first at ${first} pt)`);
  // the boxes named in the r28 fixes are on the page
  for (const box of ['34-rate', '28', '27', 'fuel-out', 'fuel-in']) assert.ok(l.texts.some((t) => t.box === box), `box ${box} is filled`);
});
