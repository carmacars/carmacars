import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument } from 'pdf-lib';
import { fillPdf, readFields, sampleForm } from './fill.ts';

test('the fields of a fillable PDF are read with their type and page', async () => {
  const { fields, pages } = await readFields(await sampleForm());
  assert.equal(pages, 1);
  assert.deepEqual(fields.map((f) => `${f.name}:${f.type}:${f.page}`), ['owner_name:text:1', 'vin:text:1', 'plate:text:1', 'postal_code:text:1', 'is_lease:checkbox:1', 'owner_signature:text:1']);
});

test('only the text boxes are filled: the checkbox and the signature are left for the counter, a missing field is named', async () => {
  const src = await sampleForm();
  const out = await fillPdf(src, { owner_name: 'OLIVE OWNER', vin: '2T1BURHE0KC123456', postal_code: 'M5V 1A1', is_lease: 'Yes', owner_signature: null, not_on_form: 'x' },
    { owner_name: { source: 'owner.legal_name' }, is_lease: { source: 'method.is_lease', type: 'checkbox' }, owner_signature: { type: 'signature' } });
  assert.deepEqual(out.missing, ['not_on_form']);
  assert.deepEqual(out.filled.sort(), ['owner_name', 'postal_code', 'vin']);
  assert.deepEqual(out.byHand.sort(), ['is_lease', 'owner_signature']);
  assert.deepEqual(Buffer.from(out.bytes.subarray(0, src.length)), Buffer.from(src), 'the original bytes come first, unchanged');
  const form = (await PDFDocument.load(out.bytes)).getForm();
  assert.equal(form.getTextField('owner_name').getText(), 'OLIVE OWNER');
  assert.equal(form.getTextField('postal_code').getText(), 'M5V 1A1');
  assert.equal(form.getCheckBox('is_lease').isChecked(), false, 'never ticked');
  assert.equal(form.getTextField('owner_signature').getText(), undefined, 'never signed');
  assert.equal(form.getFields().length, 6, 'not flattened');
});

test('nothing to fill: the PDF comes back as it was', async () => {
  const src = await sampleForm();
  const out = await fillPdf(src, { is_lease: 'Yes' }, { is_lease: { type: 'checkbox' } });
  assert.deepEqual(Buffer.from(out.bytes), Buffer.from(src));
});
