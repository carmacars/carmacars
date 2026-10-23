// The ServiceOntario forms filled for real (docs/changes/2026-10-23-form-fillers.md): the official PDFs as stored for owners
// (tests/fixtures/official-forms, from the forms-fetch workflow), the mapping of migration 0120 (maps.generated.json), and
// the registry context of four cars in the four onboarding methods (contexts.json, read from the database). Each value
// must land in its own field, inside that field's box on the page, with the owner's signature only where the owner signs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PDFCheckBox, PDFDocument, PDFDropdown, PDFTextField } from 'pdf-lib';
import { fillPdf, matchOption, readFields, type Spec } from './fill.ts';
import { ownerSigns } from './signs.ts';

const FIX = new URL('../../../tests/fixtures/official-forms/', import.meta.url);
const MAPS = JSON.parse(readFileSync(new URL('./maps.generated.json', import.meta.url), 'utf8')) as Record<string, { kind: string; map: Record<string, Spec> }>;
const CTX = JSON.parse(readFileSync(new URL('contexts.json', FIX), 'utf8')) as Record<string, Record<string, unknown>>;
const REPORT = JSON.parse(readFileSync(new URL('../../../../docs/forms/official-forms.json', import.meta.url), 'utf8')) as { forms: Array<{ code: string; fields: Array<{ name: string; type: string; page: number; rect: [number, number, number, number]; max_length?: number | null }> }> };
const pdf = (code: string) => new Uint8Array(readFileSync(new URL(`${code}.pdf`, FIX)));
// a 2 x 1 PNG: the drawn signature
const PNG = Uint8Array.from(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAEElEQVR4nGP4z8DAwMDAAAAU/wP9xI+0gAAAAABJRU5ErkJggg==', 'base64'));

// what app.fill_government_form does with a mapping and a context (0022, 0042; the transforms of app.apply_transform)
const at = (c: unknown, path: string) => { const v = path.split('.').reduce<unknown>((o, k) => (o && typeof o === 'object' ? (o as Record<string, unknown>)[k] : undefined), c); return v === null || v === undefined || String(v).trim() === '' ? null : String(v); };
function transform(v: string | null, t?: string): string | null {
  if (v === null) return null;
  if (!t) return v;
  if (t === 'upper') return v.toUpperCase();
  if (t === 'postal') { const p = v.replace(/\s/g, '').toUpperCase(); return /^[A-Z]\d[A-Z]\d[A-Z]\d$/.test(p) ? `${p.slice(0, 3)} ${p.slice(3)}` : v.toUpperCase(); }
  if (t === 'phone') { const d = v.replace(/\D/g, ''); const n = /^1?\d{10}$/.test(d) ? d.slice(-10) : null; return n ? `(${n.slice(0, 3)}) ${n.slice(3, 6)}-${n.slice(6)}` : v; }
  if (t === 'date:YYYY/MM/DD') return v.slice(0, 10).replace(/-/g, '/');
  throw new Error(`transform ${t}`);
}
function valuesFor(ctx: Record<string, unknown>, map: Record<string, Spec>): Record<string, string | null> {
  const out: Record<string, string | null> = {};
  for (const [name, s] of Object.entries(map)) {
    if (s.when && at(ctx, s.when) !== 'true') continue;
    let v = s.source ? transform(at(ctx, s.source), s.transform) : null;
    if (s.type === 'checkbox') v = v === 'true' || v === 'Yes' ? 'Yes' : 'Off';
    out[name] = v;
  }
  return out;
}
const SCEN = { S1: 'S1_lease_existing_corporation', S2: 'S2_lease_new_corporation', S3: 'S3_co_registrant', S6: 'S6_transfer_leased' } as const;
const FORMS_OF: Record<keyof typeof SCEN, string[]> = { S1: ['SR-LV-006', 'SR-LV-012'], S2: ['SR-LV-006', 'SR-LV-012', 'ON00453', '013-0169', '013-1155'], S3: ['SR-LV-006', 'SR-LV-012'], S6: ['SR-LV-006', 'SR-LV-012'] };
const fill = async (code: string, s: keyof typeof SCEN, o: { signaturePng?: Uint8Array; flatten?: boolean } = {}) => {
  const values = valuesFor(CTX[SCEN[s]]!, MAPS[code]!.map);
  return { values, ...(await fillPdf(pdf(code), values, MAPS[code]!.map, o)) };
};
const P1 = 'form1[0].page1[0].body[0].';
const text = (doc: PDFDocument, name: string) => { const f = doc.getForm().getField(name); return f instanceof PDFTextField ? f.getText() ?? '' : ''; };
const checked = (doc: PDFDocument, name: string) => (doc.getForm().getField(name) as PDFCheckBox).isChecked();

test('every mapped field is a field of the official PDF, of the same type, and every value fits its field', async () => {
  for (const [code, { kind, map }] of Object.entries(MAPS)) {
    if (kind === 'overlay') continue;
    const { fields } = await readFields(pdf(code));
    const byName = new Map(fields.map((f) => [f.name, f]));
    for (const [name, s] of Object.entries(map)) {
      const f = byName.get(name);
      assert.ok(f, `${code}: ${name} is in the PDF`);
      if (s.type === 'checkbox') assert.equal(f.type, 'checkbox', `${code}: ${name} is a checkbox`);
      if (s.type === 'dropdown') assert.equal(f.type, 'dropdown', `${code}: ${name} is a drop-down`);
    }
  }
  for (const s of Object.keys(SCEN) as Array<keyof typeof SCEN>) for (const code of FORMS_OF[s]) {
    const out = await fill(code, s);
    assert.deepEqual(out.missing, [], `${s} ${code}: every value found its field`);
    assert.deepEqual(out.truncated, [], `${s} ${code}: no value cut at the field's length`);
  }
});

test('SR-LV-006 under a Lease: the owner\'s corporation is the registrant, its address in four boxes, the plates are someone else\'s', async () => {
  const doc = await PDFDocument.load((await fill('SR-LV-006', 'S2')).bytes);
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].lastName[2]`), 'TREMBLAY MOBILITY INC.');
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].streetName[0]`), '1204 Bay Street');
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].apt[0]`), '1807');
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].city[0]`), 'Toronto');
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].postalCode[0]`), 'M5R 2A5');
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].#subform[1].date[0]`), '', 'a company has no date of birth');
  assert.equal(checked(doc, `${P1}personalInfo[0].#subform[2].#field[13]`), true, 'Number plates owned by other than above');
  assert.equal(checked(doc, `${P1}personalInfo[0].#subform[2].#field[12]`), false);
  assert.equal(text(doc, `${P1}businessInfo6[0].#field[0]`), 'W1KAF4HB5MR123456', 'section 7 names the VIN');
  assert.equal(text(doc, `${P1}businessInfo7[0].esoName[0]`), 'OLIVIA MARGARET TREMBLAY');
  const s1 = await PDFDocument.load((await fill('SR-LV-006', 'S1')).bytes);
  assert.equal(text(s1, `${P1}personalInfo[0].#subform[0].lastName[0]`), 'C9876-54321', 'the corporation\'s RIN, never a person\'s licence');
  assert.equal(text(s1, `${P1}personalInfo[0].#subform[0].apt[0]`), '2500');
  assert.equal(text(s1, `${P1}businessInfo7[0].esoName[0]`), 'DANIEL OKAFOR', 'the signing officer signs for the corporation');
});

test('SR-LV-006 under Co-Registrant: the owner by the registry\'s name order, licence and birth date; two registrants', async () => {
  const doc = await PDFDocument.load((await fill('SR-LV-006', 'S3')).bytes);
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].lastName[2]`), 'TREMBLAY, OLIVIA M');
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].lastName[0]`), 'T6512-48390-85421');
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].#subform[1].date[0]`), '1985/02/03');
  assert.equal(checked(doc, `${P1}personalInfo[0].#subform[2].#field[12]`), true);
  assert.equal(checked(doc, `${P1}personalInfo[0].#subform[2].#field[13]`), false);
});

test('SR-LV-006 under a Transfer of a leased car: the lessor keeps the vehicle, CarmaCars signs, the owner does not', async () => {
  const out = await fill('SR-LV-006', 'S6');
  const doc = await PDFDocument.load(out.bytes);
  assert.equal(text(doc, `${P1}personalInfo[0].#subform[0].lastName[2]`), 'BMW FINANCIAL SERVICES');
  assert.equal(checked(doc, `${P1}personalInfo[0].#subform[2].#field[13]`), true);
  assert.equal(text(doc, `${P1}businessInfo7[0].esoName[0]`), 'ABBAS AL-MASHITA');
  assert.equal(ownerSigns(out.values, MAPS['SR-LV-006']!.map), false);
});

test('SR-LV-012: section 1 names CarmaCars as the plate owner only when it holds the plates; section 2 only for two registrants', async () => {
  const lease = await PDFDocument.load((await fill('SR-LV-012', 'S2')).bytes);
  assert.equal(text(lease, `${P1}personalInfo[0].#subform[0].lastName[3]`), '18122211 CANADA INC.');
  assert.equal(text(lease, `${P1}personalInfo[0].#subform[0].lastName[0]`), 'R1234-56789');
  assert.equal(text(lease, `${P1}personalInfo[0].#subform[0].streetName[0]`), '2967 Dundas St W', 'the street line alone, not the whole address');
  assert.equal(text(lease, `${P1}personalInfo[0].#subform[0].apt[0]`), '208B');
  assert.equal(text(lease, `${P1}personalInfo[0].#subform[0].city[0]`), 'Toronto');
  assert.equal(text(lease, `${P1}personalInfo[0].#subform[0].postalCode[0]`), 'M6P 1Z2');
  assert.equal(text(lease, `${P1}businessInfo[0].#subform[0].lastName[3]`), '', 'section 2 stays empty');
  const co = await PDFDocument.load((await fill('SR-LV-012', 'S3')).bytes);
  assert.equal(text(co, `${P1}personalInfo[0].#subform[0].lastName[3]`), '', 'section 1 stays empty');
  assert.equal(text(co, `${P1}businessInfo[0].#subform[0].lastName[3]`), 'TREMBLAY, OLIVIA M');
  assert.equal(text(co, `${P1}businessInfo[0].#subform[0].apt[0]`), '1807');
  assert.equal(text(co, `${P1}businessInfo[0].#subform[4].lastName[7]`), '18122211 CANADA INC.');
  assert.equal(text(co, `${P1}businessInfo[0].#subform[4].city[1]`), 'Toronto');
  assert.equal(text(co, `${P1}businessInfo[0].esoName[1]`), 'ABBAS AL-MASHITA');
});

test('the tax forms and the RIN form: the owner and the corporation, street number and name apart, the phone as written, Ontario chosen', async () => {
  const c = await PDFDocument.load((await fill('013-0169', 'S2')).bytes);
  assert.equal(text(c, `${P1}SectionB[0].#subform[1].busStreetNo[0]`), '1204');
  assert.equal(text(c, `${P1}SectionB[0].#subform[1].busStreetName[0]`), 'Bay Street');
  assert.equal(text(c, `${P1}SectionB[0].#subform[1].TelephoneNo[0]`), '(416) 555-0142');
  assert.match((c.getForm().getField(`${P1}SectionB[0].#subform[1].busProvince[0]`) as PDFDropdown).getSelected()[0] ?? '', /^ON\b.*Ontario$/);
  const s = await PDFDocument.load((await fill('013-1155', 'S2')).bytes);
  assert.equal(text(s, 'nameRecipient'), 'TREMBLAY MOBILITY INC.');
  assert.equal(text(s, 'nameDonor'), 'OLIVIA MARGARET TREMBLAY');
  assert.equal(text(s, 'vehicleID'), 'W1KAF4HB5MR123456');
  const rin = await fill('ON00453', 'S2');
  assert.equal(rin.values['Section 1. Provide the name of the contact person (Director/Owner). Phone Number'], '(416) 555-0142');
  assert.equal(rin.values['Section 1. Provide Address of Physical Ontario Location. Street Number'], '1204');
});

// where pdf.js finds each value on the flattened page: inside the box of its field (2 points of slack)
async function placed(bytes: Uint8Array) {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const d = await pdfjs.getDocument({ data: bytes, verbosity: 0 }).promise;
  const pages: Array<{ items: Array<{ str: string; x: number; y: number }>; images: Array<{ x: number; y: number; w: number; h: number }> }> = [];
  for (let i = 1; i <= d.numPages; i++) {
    const p = await d.getPage(i);
    const t = await p.getTextContent();
    const ops = await p.getOperatorList();
    const images: Array<{ x: number; y: number; w: number; h: number }> = [];
    // the transform in force when each image is painted (pdf-lib draws an image as save, cm, Do, restore)
    let m: number[] = [1, 0, 0, 1, 0, 0]; const stack: number[][] = [];
    ops.fnArray.forEach((fn, k) => {
      if (fn === pdfjs.OPS.save) stack.push(m);
      else if (fn === pdfjs.OPS.restore) m = stack.pop() ?? [1, 0, 0, 1, 0, 0];
      else if (fn === pdfjs.OPS.transform) { const [a, b, c, dd, e, f] = ops.argsArray[k] as number[]; m = [m[0]! * a! + m[2]! * b!, m[1]! * a! + m[3]! * b!, m[0]! * c! + m[2]! * dd!, m[1]! * c! + m[3]! * dd!, m[0]! * e! + m[2]! * f! + m[4]!, m[1]! * e! + m[3]! * f! + m[5]!]; }
      else if (fn === pdfjs.OPS.paintImageXObject) images.push({ x: m[4]!, y: m[5]!, w: m[0]!, h: m[3]! });
    });
    pages.push({ items: (t.items as Array<{ str: string; transform: number[] }>).filter((x) => x.str.trim()).map((x) => ({ str: x.str, x: x.transform[4]!, y: x.transform[5]! })), images });
  }
  return pages;
}

test('flattened and signed: each value is printed inside its own field\'s box, and the signature only in the owner\'s signature box', async () => {
  for (const s of Object.keys(SCEN) as Array<keyof typeof SCEN>) for (const code of FORMS_OF[s]) {
    const { kind, map } = MAPS[code]!;
    const out = await fill(code, s, { signaturePng: PNG, flatten: true });
    const pages = await placed(out.bytes);
    const rects = new Map((REPORT.forms.find((f) => f.code === code)!.fields).map((f) => [f.name, { page: f.page, rect: f.rect }]));
    for (const [name, v] of Object.entries(out.values)) {
      const spec = map[name]!;
      if (!v || spec.type === 'checkbox' || spec.type === 'signature' || spec.type === 'dropdown') continue;
      const box = kind === 'overlay' ? spec.box! : rects.get(name)!;
      const [x, y, w, h] = box.rect;
      const page = pages[box.page - 1]!;
      const hit = page.items.find((i) => i.str.includes(v.slice(0, 12)) && i.x >= x - 2 && i.x <= x + w + 2 && i.y >= y - 2 && i.y <= y + h + 2);
      assert.ok(hit, `${s} ${code}: "${v}" inside ${name} (page ${box.page}, ${box.rect.map(Math.round).join(' ')}); found ${JSON.stringify(page.items.filter((i) => i.str.includes(v.slice(0, 12))))}`);
    }
    const signs = Object.entries(map).filter(([n, sp]) => sp.type === 'signature' && (!sp.when || n in out.values));
    // the images the signature added: those the same form filled without a signature does not have (the Ontario logo is one)
    const before = await placed((await fill(code, s, { flatten: true })).bytes);
    const key = (im: { x: number; y: number }, page: number) => `${page}:${im.x.toFixed(1)}:${im.y.toFixed(1)}`;
    const had = new Set(before.flatMap((p, i) => p.images.map((im) => key(im, i + 1))));
    const drawn = pages.flatMap((p, i) => p.images.map((im) => ({ ...im, page: i + 1 }))).filter((im) => !had.has(key(im, im.page)));
    assert.equal(drawn.length, signs.length, `${s} ${code}: one signature per box the owner signs`);
    for (const [n, sp] of signs) {
      const box = kind === 'overlay' ? sp.box! : rects.get(n)!;
      const [x, y, w, h] = box.rect;
      assert.ok(drawn.some((im) => im.page === box.page && im.x >= x - 1 && im.x + im.w <= x + w + 1 && im.y >= y - 1 && im.y + im.h <= y + h + 1), `${s} ${code}: the signature inside ${n}`);
    }
  }
});

test('who signs on screen: the owner under a Lease (SR-LV-006) and Co-Registrant (both forms); nobody on the plate owner\'s section', async () => {
  const signs = (code: string, s: keyof typeof SCEN) => ownerSigns(valuesFor(CTX[SCEN[s]]!, MAPS[code]!.map), MAPS[code]!.map);
  assert.deepEqual([signs('SR-LV-006', 'S1'), signs('SR-LV-006', 'S2'), signs('SR-LV-006', 'S3'), signs('SR-LV-006', 'S6')], [true, true, true, false]);
  assert.deepEqual([signs('SR-LV-012', 'S1'), signs('SR-LV-012', 'S2'), signs('SR-LV-012', 'S3'), signs('SR-LV-012', 'S6')], [false, false, true, false]);
  assert.equal(signs('ON00453', 'S2'), true);
});

test('a drop-down takes the option a value stands for, whatever the dash', () => {
  const o = ['AB - Alberta', 'MB – Manitoba', 'ON - Ontario'];
  assert.equal(matchOption(o, 'ON'), 'ON - Ontario');
  assert.equal(matchOption(o, 'manitoba'), 'MB – Manitoba');
  assert.equal(matchOption(o, 'ON - Ontario'), 'ON - Ontario');
  assert.equal(matchOption(o, 'QC'), null);
});
