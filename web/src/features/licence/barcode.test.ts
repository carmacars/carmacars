// The back's barcode read from a photo, in pure JavaScript (release 31, D2). The fixture is a made-up card: a PDF417
// of invented AAMVA data on a grey card, turned two degrees. npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodeImage, readPdf417, shrink, smallJpegDataUrl } from './barcode.ts';
import { parseAamva } from './aamva.ts';

const photo = new Uint8Array(readFileSync(new URL('./fixtures/back-fake.jpg', import.meta.url)));

test('barcode: the PDF417 on a photo of the back, read and parsed', () => {
  const img = decodeImage(photo)!;
  assert.ok(img.width > 900);
  const text = readPdf417(img);
  assert.ok(text, 'barcode read');
  const f = parseAamva(text!)!;
  assert.equal(f.last_name, 'Driver');
  assert.equal(f.date_of_birth, '1990-12-25');
  assert.equal(f.issuer, 'ON');
});

test('barcode: no barcode, no text; a small JPEG for the vision model', () => {
  const img = decodeImage(photo)!;
  const blank = { width: 400, height: 300, data: new Uint8Array(400 * 300 * 4).fill(200) };
  assert.equal(readPdf417(blank), null);
  assert.equal(shrink(img, 300).width, 300);
  assert.match(smallJpegDataUrl(img, 300), /^data:image\/jpeg;base64,\/9j\//);
  assert.equal(decodeImage(new Uint8Array([1, 2, 3])), null);
});
