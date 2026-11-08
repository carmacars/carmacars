import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument } from 'pdf-lib';
import { fillPdf, sampleForm } from './fill.ts';

// r35 (0870): a value changed by hand on one form is a value of the form's box, nothing more. The database puts it in
// the fill's field_values (a box the mapping does not fill as well); the browser fills the publisher's PDF with it.
test('a value changed by hand fills its box, even one the mapping leaves empty; the publisher\'s bytes stay first and unchanged', async () => {
  const src = await sampleForm();
  const map = { owner_name: { source: 'owner.legal_name' } };
  const out = await fillPdf(src, { owner_name: 'EXAMPLE, PAT Q', plate: 'SMPL 001' }, map);
  assert.deepEqual(out.filled.sort(), ['owner_name', 'plate']);
  assert.deepEqual(Buffer.from(out.bytes.subarray(0, src.length)), Buffer.from(src), 'an incremental update after the last byte: the form itself is not set again');
  const form = (await PDFDocument.load(out.bytes)).getForm();
  assert.equal(form.getTextField('owner_name').getText(), 'EXAMPLE, PAT Q');
  assert.equal(form.getTextField('plate').getText(), 'SMPL 001');
  assert.equal(form.getFields().length, 6, 'the same fields, not flattened');
});

test('a box emptied by hand is left empty', async () => {
  const src = await sampleForm();
  const out = await fillPdf(src, { owner_name: null, vin: '2HGFC2F59MH000001' }, { owner_name: { source: 'owner.legal_name' }, vin: { source: 'vehicle.vin' } });
  const form = (await PDFDocument.load(out.bytes)).getForm();
  assert.equal(form.getTextField('owner_name').getText(), undefined);
  assert.equal(form.getTextField('vin').getText(), '2HGFC2F59MH000001');
});
