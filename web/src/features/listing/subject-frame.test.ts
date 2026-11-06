import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FRAME, STUDIO, decodePng, encodePng, frameSubject, placeSubject, subjectCells, type Rgba } from './subject-frame.ts';

/** A segmenter's cut-out: a 1000 x 650 clear frame, a car (a solid body with two wheels) in the middle at 40% of the width
 *  standing well above the bottom, a corner watermark and a caption's letters, as the Mercedes sources have. */
function cutout(): Rgba {
  const W = 1000, H = 650, data = new Uint8ClampedArray(W * H * 4);
  const fill = (x0: number, y0: number, x1: number, y1: number, rgb = [200, 20, 30]) => {
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const i = (y * W + x) * 4; data[i] = rgb[0]!; data[i + 1] = rgb[1]!; data[i + 2] = rgb[2]!; data[i + 3] = 255; }
  };
  fill(300, 260, 700, 400);                        // the body
  fill(330, 400, 390, 440, [20, 20, 20]); fill(610, 400, 670, 440, [20, 20, 20]);   // the wheels
  fill(500, 230, 512, 262);                        // a detached mirror inside the car's box
  for (let k = 0; k < 6; k++) fill(850 + k * 22, 600, 864 + k * 22, 625, [255, 255, 255]);   // the corner mark's letters
  for (let k = 0; k < 9; k++) fill(40 + k * 20, 20, 52 + k * 20, 40, [255, 255, 255]);       // a caption at the top
  return { width: W, height: H, data };
}

test('the car is the largest piece; a corner mark and a caption are left out, a mirror inside the car is kept', () => {
  const c = subjectCells(cutout())!;
  assert.equal(c.dropped, 15);
  assert.deepEqual([c.car.x0 * FRAME.cell, c.car.x1 * FRAME.cell + FRAME.cell], [300, 700]);
});

test('the framed cut-out is the car to its edges, with the shadow below it and no mark anywhere', async () => {
  const png = await encodePng(cutout());
  const f = (await frameSubject(png))!;
  assert.ok(f);
  assert.equal(f.dropped, 15);
  const img = (await decodePng(f.png))!;
  const carW = 400, padS = Math.round(carW * FRAME.side), padB = Math.round(carW * FRAME.ground);
  assert.equal(img.width, carW + 2 * padS);
  assert.equal(img.height, 440 - 230 + padB);
  // no white (the mark's or the caption's colour) survives
  let white = 0;
  for (let i = 0; i < img.data.length; i += 4) if (img.data[i]! > 240 && img.data[i + 1]! > 240 && img.data[i + 3]! > 0) white++;
  assert.equal(white, 0);
  // under the wheels: a dark, partly clear shadow, darkest at the tyre line
  const at = (x: number, y: number) => img.data[(y * img.width + x) * 4 + 3]!;
  const cx = Math.round(img.width / 2), wheelLine = 440 - 230 - 1;
  assert.ok(at(cx, wheelLine + 2) > at(cx, wheelLine + padB - 2), 'the shadow fades away from the car');
  assert.ok(at(cx, wheelLine + 2) > 100 && at(cx, wheelLine + 2) < 255);
  assert.equal(img.data[((wheelLine + 2) * img.width + cx) * 4], 0, 'the shadow is black');
  assert.ok(Math.abs(f.ground - padB / img.height) < 1e-9);
  assert.ok(f.share.w > 0.39 && f.share.w < 0.41);
});

test('placed in the studio: about 80% of the width for a side view, the wheels on the floor line, centred', () => {
  const W = 1800, H = 1200;
  const side = placeSubject({ width: 1300, height: 450, ground: 0.12, side: 0.035 }, W, H);
  assert.ok(side.carShare >= 0.75 && side.carShare <= 0.85, `side view ${side.carShare}`);
  const wheels = side.bottom + side.height * 0.12;
  assert.ok(Math.abs(wheels - H * STUDIO.floor) <= 1, 'the wheels stand on the floor line');
  assert.equal(side.left, Math.round((W - side.width) / 2));
  // a three-quarter view keeps close to the same share; a front view is held by the height and never leaves the frame
  const three = placeSubject({ width: 1100, height: 560, ground: 0.1, side: 0.035 }, W, H);
  assert.ok(three.carShare >= 0.75, `three-quarter ${three.carShare}`);
  const front = placeSubject({ width: 900, height: 760, ground: 0.065, side: 0.035 }, W, H);
  assert.ok(front.bottom + front.height <= H && front.width <= W);
});

test('a PNG that is not RGBA, or a clear cut-out, is not framed (the worker frames it as before)', async () => {
  assert.equal(await frameSubject(new Uint8Array([1, 2, 3])), null);
  assert.equal(await frameSubject(await encodePng({ width: 40, height: 30, data: new Uint8ClampedArray(40 * 30 * 4) })), null);
});

test('an RGB or palette PNG (a preview for the touch-up) is read too', async () => {
  const zlib = await import('node:zlib');
  const crc = (b: Buffer) => { let c = ~0; for (const x of b) { c ^= x; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; } return (~c) >>> 0; };
  const chunk = (t: string, body: Buffer) => { const len = Buffer.alloc(4); len.writeUInt32BE(body.length); const tb = Buffer.concat([Buffer.from(t), body]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(tb)); return Buffer.concat([len, tb, c]); };
  const png = (colour: number, raw: number[], extra: Buffer[] = []) => { const ih = Buffer.alloc(13); ih.writeUInt32BE(2, 0); ih.writeUInt32BE(1, 4); ih[8] = 8; ih[9] = colour;
    return new Uint8Array(Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ih), ...extra, chunk('IDAT', zlib.deflateSync(Buffer.from(raw))), chunk('IEND', Buffer.alloc(0))])); };
  const rgb = (await decodePng(png(2, [0, 10, 20, 30, 40, 50, 60])))!;
  assert.deepEqual([...rgb.data], [10, 20, 30, 255, 40, 50, 60, 255]);
  const pal = (await decodePng(png(3, [0, 1, 0], [chunk('PLTE', Buffer.from([1, 2, 3, 200, 150, 100])), chunk('tRNS', Buffer.from([0]))])))!;
  assert.deepEqual([...pal.data], [200, 150, 100, 255, 1, 2, 3, 0]);
});
