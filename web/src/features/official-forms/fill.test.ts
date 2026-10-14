import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument } from 'pdf-lib';
import { fillPdf, readFields, sampleForm } from './fill.ts';

// a 2 x 1 PNG (red, black): the drawn signature
const PNG = Uint8Array.from(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAEElEQVR4nGP4z8DAwMDAAAAU/wP9xI+0gAAAAABJRU5ErkJggg==', 'base64'));

test('the fields of a fillable PDF are read with their type and page', async () => {
  const { fields, pages } = await readFields(await sampleForm());
  assert.equal(pages, 1);
  assert.deepEqual(fields.map((f) => `${f.name}:${f.type}:${f.page}`), ['owner_name:text:1', 'vin:text:1', 'plate:text:1', 'postal_code:text:1', 'is_lease:checkbox:1', 'owner_signature:text:1']);
});

test('a form is filled with the values, the checkbox ticked, the signature drawn, and a missing field named', async () => {
  const out = await fillPdf(await sampleForm(), { owner_name: 'OLIVE OWNER', vin: '2T1BURHE0KC123456', postal_code: 'M5V 1A1', is_lease: 'Yes', not_on_form: 'x' },
    { owner_name: { source: 'owner.legal_name' }, owner_signature: { type: 'signature' } }, { signaturePng: PNG });
  assert.deepEqual(out.missing, ['not_on_form']);
  assert.ok(out.filled.includes('owner_signature'));
  const doc = await PDFDocument.load(out.bytes);
  const form = doc.getForm();
  assert.equal(form.getTextField('owner_name').getText(), 'OLIVE OWNER');
  assert.equal(form.getTextField('postal_code').getText(), 'M5V 1A1');
  assert.equal(form.getCheckBox('is_lease').isChecked(), true);
});

test('the signed copy is flattened: no field can be changed afterwards', async () => {
  const out = await fillPdf(await sampleForm(), { owner_name: 'OLIVE OWNER' }, { owner_signature: { type: 'signature' } }, { signaturePng: PNG, flatten: true });
  const doc = await PDFDocument.load(out.bytes);
  assert.equal(doc.getForm().getFields().length, 0);
});
