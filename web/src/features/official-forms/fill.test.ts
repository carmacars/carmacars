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

test('a form with no fillable field (a coordinates-based template) gets its values drawn in their boxes, the signature too', async () => {
  const flat = await PDFDocument.create();
  flat.addPage([612, 792]);
  const out = await fillPdf(await flat.save(), { 'Organization name': 'SAMPLE HOLDINGS INC', 'Purpose: New': 'Yes', 'Not boxed': 'x' },
    { 'Organization name': { source: 'corporation.name', box: { page: 1, rect: [20, 700, 300, 14] } },
      'Purpose: New': { source: 'method.is_lease', type: 'checkbox', box: { page: 1, rect: [20, 650, 10, 12] } },
      Signature: { type: 'signature', box: { page: 1, rect: [20, 500, 160, 30] } } }, { signaturePng: PNG, flatten: true });
  assert.deepEqual(out.missing, ['Not boxed']);
  assert.deepEqual(out.filled.sort(), ['Organization name', 'Purpose: New', 'Signature']);
  const doc = await PDFDocument.load(out.bytes);
  assert.equal(doc.getPageCount(), 1);
  assert.ok(out.bytes.length > (await flat.save()).length + 500, 'text and the image were drawn');
});
