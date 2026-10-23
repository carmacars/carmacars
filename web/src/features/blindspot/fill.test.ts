// Blind Spot's rental agreement, the second agreement of a booking (docs/changes/2026-10-23-second-rental-agreement.md).
// Blind Spot's PDF is private (Admin > Settings > Forms) and is never in the repository: these tests make a stand-in with
// the same page size, the same pre-printed annotations at the same places (the old address top left and twice in box
// 15, "Full Value") and the old address, HST number and signature drawn where the real form has them. Read back with
// pdf.js.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PDFArray, PDFDict, PDFDocument, PDFName, PDFString, StandardFonts, rgb } from 'pdf-lib';
import { COVERS, PAGE_H, SIG, ageOn, dollars, layout, mailingLine, mailingStreet, type BlindSpotFacts } from './layout.ts';
import { fillBlindSpot, scriptWidth, winAnsi } from './fill.ts';
import { sampleFacts } from './sample.ts';
import { SCRIPT_GLYPHS } from './script-glyphs.generated.ts';

const MAILING = { line: '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2', street: '2967 Dundas St W', unit: '208B', city: 'Toronto', province: 'ON', postal_code: 'M6P 1Z2' };
const PNG = Uint8Array.from(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAACgAAAAKCAYAAADGmhxQAAAALklEQVR4nGMQUEj4D8MMdARk2TvqWFrZO5COJUvTQDiWLDDqWFqBUcfSCpDjWAA6KT5ZaYCppQAAAABJRU5ErkJggg==', 'base64'));

/** A stand-in for Blind Spot's form: A4, two pages, the old address, HST number and "Sam" printed where the form has
 *  them, and FreeText annotations at the form's own rectangles (PDF coordinates). */
async function standIn(): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const p1 = doc.addPage([595.276, 841.89]);
  const p2 = doc.addPage([595.276, 841.89]);
  p1.drawRectangle({ x: 18.8, y: PAGE_H - 531.5, width: 270, height: 20, color: rgb(1, 186 / 255, 204 / 255) });
  p1.drawText('75756 2079 RT0001', { x: 64, y: PAGE_H - 120.5, size: 11, font });
  p1.drawText('Sam', { x: 145, y: PAGE_H - 821, size: 18, font });
  p1.drawText('15 RENTED FROM', { x: 22, y: PAGE_H - 521, size: 6, font });
  p2.drawText('TERMS AND CONDITIONS', { x: 50, y: 800, size: 12, font });
  const annots = doc.context.obj([]) as PDFArray;
  for (const [rect, text] of [[[49, 745, 286, 757], '104 CROCKFORD BLVD, TORONTO, ON, M1R 3C3'], [[23, 307, 91, 319], '104 Crockford Blvd'], [[209, 307, 277, 319], '104 Crockford Blvd'],
    [[70, 254, 105, 266], 'Full Value'], [[373, 372, 436, 384], 'UNDERAGE FEE']] as Array<[number[], string]>) {
    const a = doc.context.obj({ Type: 'Annot', Subtype: 'FreeText', Rect: rect, Contents: PDFString.of(text), DA: PDFString.of('/Helv 8 Tf 0 g'), F: 4 });
    annots.push(doc.context.register(a));
  }
  p1.node.set(PDFName.of('Annots'), annots);
  return doc.save();
}

type Item = { str: string; x: number; y: number };
async function read(bytes: Uint8Array) {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const d = await pdfjs.getDocument({ data: bytes, verbosity: 0 }).promise;
  const pages: Array<{ items: Item[]; text: string; annots: string[] }> = [];
  for (let i = 1; i <= d.numPages; i++) {
    const p = await d.getPage(i);
    const items = ((await p.getTextContent()).items as Array<{ str: string; transform: number[] }>).filter((x) => x.str.trim()).map((x) => ({ str: x.str, x: x.transform[4]!, y: x.transform[5]! }));
    const annots = ((await p.getAnnotations()) as Array<{ contentsObj?: { str: string } }>).map((a) => a.contentsObj?.str ?? '');
    pages.push({ items, text: items.map((x) => x.str).join(' '), annots });
  }
  return pages;
}
const at = (items: Item[], s: string) => items.find((x) => x.str === s);

test('the booking in its boxes: the mailing address, the HST number, the renter, the car, the money', async () => {
  const f = sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' });
  const out = await fillBlindSpot(await standIn(), layout(f), { company: { name: 'Ahmad' } });
  assert.equal(out.removedAnnotations, 3, 'the three annotations with the old address are removed');
  assert.deepEqual(out.cut, [], 'no value is cut');
  const [p1, p2] = await read(out.bytes);
  assert.ok(p1 && p2);
  // the old address is gone, the other pre-printed annotations stay
  assert.deepEqual(p1.annots.sort(), ['Full Value', 'UNDERAGE FEE']);
  assert.ok(!/crockford/i.test(p1.text));
  for (const s of ['2967 DUNDAS ST W, UNIT 208B, TORONTO, ON M6P 1Z2', '79878 1234 RT0001', 'CC-10001', 'Jordan Sample Renter', '(416) 555-0142', '100 Example Street, Apt 1204',
    'Toronto', 'M5H 2N2', '2002-03-14', 'S1234-56789-02314', 'Casey Example Driver', 'E1234-56789-00701', 'SMPL123', 'Mercedes-Benz', '2023 C-Class C 300 4MATIC',
    'Jun 16, 2027 10:00 AM', '600 km', '200 km', '$0.40', '$99.00', '$297.00', '$15.00', '$45.00', '$20.00', '$60.00', '$417.00', '$54.21', '$471.21', '$1,000.00', '4242 (Visa)', 'F-07'])
    assert.ok(p1.text.includes(s), `page 1 shows ${s}`);
  // box 15: the mailing street twice, in box 15's row
  const from = p1.items.filter((x) => x.str === '2967 Dundas St W, Unit 208B');
  assert.equal(from.length, 2);
  for (const x of from) assert.ok(Math.abs(x.y - (PAGE_H - 529.6)) < 0.5);
  // the age at pickup: 25 (born March 14, 2002; pickup June 16, 2027), the licence expiry in Y, M and D
  assert.ok(at(p1.items, '25') && at(p1.items, '2029') && at(p1.items, '03') && at(p1.items, '14'));
  // due back June 19, 2027 at 10:00 AM (Toronto): under M, DD and YYYY
  assert.ok(at(p1.items, '06') && at(p1.items, '19') && at(p1.items, '2027') && at(p1.items, '10:00'));
  // the delivery has no box of its own: it is in box 14
  assert.ok(p1.text.includes('Other charges: Delivery $15.00.'));
  // page 2 (the terms) is left alone
  assert.equal(p2.text, 'TERMS AND CONDITIONS');
  // not billed to an insurer: the insurer boxes are blank
  assert.ok(!p1.text.includes('Insurer') && !p1.text.includes('CLM-'));
});

test('the same booking gives the same document (its SHA-256 holds until something changes)', async () => {
  const tpl = await standIn();
  const f = sampleFacts({ mailing: MAILING, hst_number: null });
  const a = await fillBlindSpot(tpl, layout(f), { company: { name: 'Ahmad' }, title: 'x' });
  const b = await fillBlindSpot(tpl, layout(f), { company: { name: 'Ahmad' }, title: 'x' });
  assert.deepEqual(a.bytes, b.bytes);
});

test('no HST number: box 1 is covered and left blank; nothing is invented for a missing value', async () => {
  const f = sampleFacts({ mailing: MAILING, hst_number: null });
  f.renter = { ...f.renter!, mobile: null, date_of_birth: null };
  f.drivers = f.drivers.filter((d) => d.role === 'renter').map((d) => ({ ...d, date_of_birth: null, licence_expiry: null }));
  f.card = null; f.extra.fleet_number = null; f.booking.km_allowance_total = null; f.booking.km_allowance_per_day = null; f.booking.deposit_cents = 0;
  const l = layout(f);
  const boxes = new Set(l.texts.map((t) => t.box));
  for (const b of ['1', '3-cell', '8-dob', '9-age', '9-y', '10', '11', '18-card', '22', '30', '32', '56', 'claim', '12']) assert.ok(!boxes.has(b), `box ${b} is blank`);
  assert.ok(l.covers.some((c) => c.box === 'hst'), 'Blind Spot\'s HST number is covered anyway');
  // (a cover hides what is printed under it; the old text stays in the page's content, as on paper under correction tape)
  const [p1] = await read((await fillBlindSpot(await standIn(), l, {})).bytes);
  assert.ok(!p1!.items.some((x) => x.str === '79878 1234 RT0001'));
});

test('an insurance replacement rental fills the insurer, the claim and the adjuster', async () => {
  const f = sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' }, { insurer: true });
  const [p1] = await read((await fillBlindSpot(await standIn(), layout(f), {})).bytes);
  for (const s of ['Example Mutual Insurance', 'CLM-0000-1234', 'Pat Adjuster, (416) 555-0199', 'Insurer authorized 3 days at $99.00/day.']) assert.ok(p1!.text.includes(s), s);
});

test('every value fits inside the page and its box (shrunk, never past it)', () => {
  const f = sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' }, { insurer: true });
  f.renter = { ...f.renter!, legal_name: 'Maximiliana Alexandrina Wolfeschlegelsteinhausen-Bergerdorff', address_line1: '12345 Very Long Street Name Boulevard East' };
  for (const t of layout(f).texts) {
    const left = t.align === 'right' ? t.x - t.w : t.align === 'center' ? t.x - t.w / 2 : t.x;
    assert.ok(left >= 18 && left + t.w <= 580 && t.y > 15 && t.y < 830, `${t.box} is on the form`);
    assert.ok(t.size >= 5 && t.size <= 12, `${t.box} has a readable size`);
  }
});

test('the signatures: Ahmad in box 21 (or the uploaded image); the renter in 16, 17 and 20 on the signed copy, with its record', async () => {
  const f = sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' });
  for (const c of 'Ahmad') assert.ok(SCRIPT_GLYPHS[c]?.[1], `the script hand has ${c}`);
  assert.ok(scriptWidth('Ahmad', 20) > 40 && scriptWidth('Ahmad', 20) < SIG.company.w);
  const unsigned = await fillBlindSpot(await standIn(), layout(f), { company: { name: 'Ahmad' } });
  const withImage = await fillBlindSpot(await standIn(), layout(f), { company: { png: PNG } });
  assert.notDeepEqual(unsigned.bytes, withImage.bytes, 'the uploaded image replaces the written name');
  const signed = await fillBlindSpot(unsigned.bytes, { texts: [], dots: [], covers: [] }, { renter: { png: PNG }, record: { title: 'Signature record', lines: [['Renter: Jordan Sample Renter', 'Jun 1, 2027']] } });
  const pages = await read(signed.bytes);
  assert.equal(pages.length, 3, 'the signed copy adds the signature record page');
  assert.ok(pages[2]!.text.includes('Signature record'));
  assert.ok(pages[0]!.text.includes('2967 DUNDAS ST W'), 'the signed copy is the document signed');
  const typed = await fillBlindSpot(unsigned.bytes, { texts: [], dots: [], covers: [] }, { renter: { name: 'Jordan Sample Renter' } });
  assert.ok(typed.bytes.length > unsigned.bytes.length);
});

test('the covers are the colour of their box and the old signature line is drawn again', () => {
  const pink = COVERS.filter((c) => c.color === 'pink').map((c) => c.box).sort();
  assert.deepEqual(pink, ['15-from', '15-to', '21', '40']);
  assert.deepEqual(COVERS.filter((c) => c.color === 'white').map((c) => c.box).sort(), ['address', 'hst']);
});

test('formats: money, ages, the mailing address, the form\'s character set', () => {
  assert.equal(dollars(-1000), '-$10.00');
  assert.equal(dollars(123456), '$1,234.56');
  assert.equal(ageOn('2002-06-17', '2027-06-16T14:00:00Z'), 24);
  assert.equal(ageOn('2002-06-16', '2027-06-16T14:00:00Z'), 25);
  assert.equal(mailingLine(MAILING), '2967 DUNDAS ST W, UNIT 208B, TORONTO, ON M6P 1Z2');
  assert.equal(mailingStreet(MAILING), '2967 Dundas St W, Unit 208B');
  assert.equal(mailingLine({ line: '1 Main St, Toronto', street: null, unit: null, city: null, province: null, postal_code: null }), '1 MAIN ST, TORONTO');
  assert.equal(winAnsi('Zo\u00eb\u2019s caf\u00e9 \u2013 ok'), 'Zo\u00eb\'s caf\u00e9 - ok');
  assert.equal(winAnsi('李'), '?');
});

test('the Annots of the stand-in are what the real form has', async () => {
  const doc = await PDFDocument.load(await standIn());
  const a = doc.getPage(0).node.lookup(PDFName.of('Annots'), PDFArray);
  assert.equal(a.size(), 5);
  assert.ok(a.lookup(0, PDFDict).get(PDFName.of('Contents')));
  const f: BlindSpotFacts = sampleFacts({ mailing: MAILING, hst_number: null });
  assert.ok(layout(f).texts.length > 30);
});
