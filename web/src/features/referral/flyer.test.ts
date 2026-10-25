// The flyer for a partner's counter (migration 0164): one Letter page of a PDF with a QR code. npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument } from 'pdf-lib';
import { flyerPdf, qrMatrix } from './flyer.ts';

test('the QR code is a square of modules with the three finder squares', () => {
  const m = qrMatrix('https://carmacars.ca/r/AB12CD');
  assert.ok(m.length >= 21);
  assert.ok(m.every((r) => r.length === m.length));
  assert.ok(m[0]![0] && m[0]![6] && m[6]![0], 'finder pattern corners are dark');
  assert.ok(m[m.length - 1]![0] || m[m.length - 7]![0]);
});

test('the flyer is a one-page PDF', async () => {
  const b = await flyerPdf({ business: 'Test Collision', code: 'AB12CD', link: 'https://carmacars.ca/r/AB12CD', kind: 'body_shop', phone: '416-555-0142' });
  assert.equal(Buffer.from(b.slice(0, 5)).toString('latin1'), '%PDF-');
  assert.equal((await PDFDocument.load(b)).getPageCount(), 1);
});
