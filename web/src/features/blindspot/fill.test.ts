// Blind Spot's rental agreement, the second agreement of a booking (docs/changes/2026-10-23-second-rental-agreement.md).
// Blind Spot's PDF is private (Admin > Settings > Forms) and is never in the repository: these tests make a stand-in with
// the same page size, the same pre-printed annotations at the same places (the old address top left and twice in box
// 15, "Full Value") and the old address, HST number and signature drawn where the real form has them. Read back with
// pdf.js.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PDFArray, PDFDict, PDFDocument, PDFName } from 'pdf-lib';
import { COVERS, PAGE_H, SIG, SIGNED_ON, ageOn, dollars, fuelText, layout, mailingLine, mailingStreet, signedDay, type BlindSpotFacts } from './layout.ts';
import { richFacts } from '../agreement/rich-fixture.ts';
import type { AgreementExtra, Line } from '../agreement/extra.ts';
import { fillBlindSpot, scriptWidth, winAnsi } from './fill.ts';
import { sampleFacts } from './sample.ts';
import { standIn } from './stand-in.ts';
import { SCRIPT_GLYPHS } from './script-glyphs.generated.ts';

const MAILING = { line: '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2', street: '2967 Dundas St W', unit: '208B', city: 'Toronto', province: 'ON', postal_code: 'M6P 1Z2' };
const PNG = Uint8Array.from(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAACgAAAAKCAYAAADGmhxQAAAALklEQVR4nGMQUEj4D8MMdARk2TvqWFrZO5COJUvTQDiWLDDqWFqBUcfSCpDjWAA6KT5ZaYCppQAAAABJRU5ErkJggg==', 'base64'));

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
  // the delivery has no box of its own: its amount is in box 48 (pre adjustment), so the subtotal adds up, and box 14 names it
  assert.ok(p1.text.includes('Box 48: Delivery $15.00.'));
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
  f.extra.coverage = null; // card coverage with no proof recorded and no card: boxes 12 and 13 stay blank
  f.card = null; f.extra.fleet_number = null; f.booking.km_allowance_total = null; f.booking.km_allowance_per_day = null; f.booking.deposit_cents = 0;
  const l = layout(f);
  const boxes = new Set(l.texts.map((t) => t.box));
  for (const b of ['1', '3-cell', '8-dob', '9-age', '9-y', '10', '11', '18-card', '22', '30', '32', '56', 'claim', '12']) assert.ok(!boxes.has(b), `box ${b} is blank`);
  assert.ok(l.covers.some((c) => c.box === 'hst'), 'Blind Spot\'s HST number is covered anyway');
  // (a cover hides what is printed under it; the old text stays in the page's content, as on paper under correction tape)
  const [p1] = await read((await fillBlindSpot(await standIn(), l, {})).bytes);
  assert.ok(!p1!.items.some((x) => x.str === '79878 1234 RT0001'));
});

test('0178: boxes 12 and 13 carry the coverage of every booking: card coverage, the protection plan, OPCF 27', async () => {
  const card = sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' });
  const [c1] = await read((await fillBlindSpot(await standIn(), layout(card), {})).bytes);
  for (const s of ['79878 1234 RT0001', 'Assurant (credit card rental coverage)', 'Visa card ending 4242']) assert.ok(c1!.text.includes(s), s);
  const plan = sampleFacts({ mailing: MAILING, hst_number: null });
  plan.booking.coverage_option = 3; plan.extra.coverage = { ...plan.extra.coverage!, coverage_option: 3, card_issuer: null, card_last4: null, coverage_provider: null, activation_ref: 'ACT-5521' };
  const [p1] = await read((await fillBlindSpot(await standIn(), layout(plan), {})).bytes);
  for (const s of ['CarmaCars Protection Plan (rental coverage)', 'ACT-5521']) assert.ok(p1!.text.includes(s), s);
  const opcf = sampleFacts({ mailing: MAILING, hst_number: null });
  opcf.booking.coverage_option = 1; opcf.extra.coverage = { coverage_option: 1, insurer_name: 'Example Auto Insurance', policy_number: 'POL-778', policy_expiry: '2027-09-01', card_issuer: null, card_last4: null };
  const [o1] = await read((await fillBlindSpot(await standIn(), layout(opcf), {})).bytes);
  for (const s of ["Example Auto Insurance (renter's OPCF 27)", 'POL-778']) assert.ok(o1!.text.includes(s), s);
});

test('0178: a box that does not apply says N/A; the insurer boxes are not N/A on an insurance replacement', () => {
  const l = layout(sampleFacts({ mailing: MAILING, hst_number: null }));
  const na = new Set(l.texts.filter((t) => t.text === 'N/A').map((t) => t.box));
  for (const b of ['2-na', '3-home-na', '7-na', '7-office-na', '8-na', '15-dest-na', 'r-22-na', 'insured-na', 'claim-na', 'adjuster-na', '43-amount-na', '45-amount-na', '46-amount-na', '47-amount-na', 'waiver-amount-na']) assert.ok(na.has(b), b);
  assert.ok(!na.has('10-na') && !na.has('42-amount-na') && !na.has('cdw-amount-na'), 'a driver and the charges on the rental are not N/A');
  const ins = new Set(layout(sampleFacts({ mailing: MAILING, hst_number: null }, { insurer: true })).texts.filter((t) => t.text === 'N/A').map((t) => t.box));
  assert.ok(!ins.has('claim-na') && !ins.has('13-expiry-na'));
});

test('an insurance replacement rental fills the insurer, the claim and the adjuster', async () => {
  const f = sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' }, { insurer: true });
  const [p1] = await read((await fillBlindSpot(await standIn(), layout(f), {})).bytes);
  for (const s of ['Example Mutual Insurance', 'CLM-0000-1234', 'Pat Adjuster, (416) 555-0199', 'Insurer authorized 3 days at $99.00/day.']) assert.ok(p1!.text.includes(s), s);
});

// 0191: an insurance replacement with the charges to the insurer (a rate a day each, 3 days)
const INSURER_LINES = [
  { charge_type: 'vlf', description: 'VLF (vehicle licence fee): 3 days at $5.00 a day', amount_cents: 1500 },
  { charge_type: 'ldw', description: 'LDW (loss damage waiver): 3 days at $15.00 a day', amount_cents: 4500 },
  { charge_type: 'tldw', description: 'T&LDW (theft and loss damage waiver): 3 days at $10.00 a day', amount_cents: 3000 },
  { charge_type: 'pap_pec', description: 'PAP/PEC (personal accident and effects coverage): 3 days at $7.00 a day', amount_cents: 2100 },
  { charge_type: 'waiver_saver', description: 'Waiver Saver: 3 days at $3.00 a day', amount_cents: 900 }
];
function withInsurerFees(lines = INSURER_LINES): BlindSpotFacts {
  const f = sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' }, { insurer: true });
  f.lines = [...f.lines, ...lines];
  const sub = f.lines.reduce((t, l) => t + l.amount_cents, 0);
  f.booking.subtotal_at_booking_cents = sub; f.booking.hst_at_booking_cents = Math.round(sub * 0.13); f.booking.total_due_at_booking_cents = sub + Math.round(sub * 0.13);
  return f;
}
const cents = (s: string | undefined) => (s ? Math.round(Number(s.replace(/[$,]/g, '')) * 100) : 0);

test('0191: each charge to the insurer in its box, with its rate a day; the box shows it instead of N/A', async () => {
  const l = layout(withInsurerFees());
  const by = (b: string) => l.texts.find((t) => t.box === b)?.text;
  assert.deepEqual([by('43-rate'), by('43-amount')], ['$5.00', '$15.00'], 'VLF, box 43');
  assert.deepEqual([by('45-rate'), by('45-amount')], ['$15.00', '$45.00'], 'LDW, box 45');
  assert.deepEqual([by('46-rate'), by('46-amount')], ['$10.00', '$30.00'], 'T&LDW, box 46');
  assert.deepEqual([by('47-rate'), by('47-amount')], ['$7.00', '$21.00'], 'PAP/PEC, box 47');
  assert.equal(by('waiver-amount'), '$9.00', 'Waiver Saver, its white box');
  for (const b of ['43-amount-na', '45-amount-na', '46-amount-na', '47-amount-na', 'waiver-amount-na']) assert.ok(!by(b), `${b}: charged, not N/A`);
  // each on its row: the rate in the per-day column (x 448), the amount right-aligned at 577
  for (const [b, y] of [['43', 508], ['45', 549], ['46', 569.5], ['47', 590]] as const) {
    const rate = l.texts.find((t) => t.box === `${b}-rate`)!; const amt = l.texts.find((t) => t.box === `${b}-amount`)!;
    assert.deepEqual([rate.x, rate.y, rate.w, rate.size, amt.x, amt.y, amt.w, amt.align], [448, y, 38, 7, 577, y, 72, 'right'], `box ${b}`);
  }
  const w = l.texts.find((t) => t.box === 'waiver-amount')!;
  assert.deepEqual([w.x, w.y, w.w, w.size], [409, 607, 28, 7]);
  // drawn on the form, nothing cut
  const out = await fillBlindSpot(await standIn(), l, {});
  assert.deepEqual(out.cut, []);
  const [p1] = await read(out.bytes);
  for (const s of ['$5.00', '$15.00', '$45.00', '$30.00', '$7.00', '$21.00', '$9.00']) assert.ok(p1!.text.includes(s), s);
});

test('0191: the charges to the insurer stay out of box 48 and box 14, and the subtotal adds up exactly', () => {
  const f = withInsurerFees();
  const l = layout(f);
  const by = (b: string) => l.texts.find((t) => t.box === b)?.text;
  assert.equal(by('48'), '$15.00', 'box 48: the delivery only');
  const info = l.texts.filter((t) => t.box.startsWith('14-')).map((t) => t.text).join(' ');
  assert.ok(info.includes('Box 48: Delivery $15.00.'), info);
  assert.ok(!/VLF|LDW|PAP|Waiver/.test(info), 'box 14 does not list them');
  const boxes = ['39', '42-amount', 'cdw-amount', '43-amount', '44-amount', '45-amount', '46-amount', '47-amount', 'waiver-amount', '48'].reduce((t, b) => t + cents(by(b)), 0);
  assert.equal(boxes, f.booking.subtotal_at_booking_cents, 'the boxes add up to the subtotal');
  assert.equal(cents(by('49')), f.booking.subtotal_at_booking_cents, 'box 49');
});

test('0191: a Waiver Saver too wide for its white box goes to box 48 (and box 14 names it)', () => {
  const f = withInsurerFees([...INSURER_LINES.slice(0, 4), { charge_type: 'waiver_saver', description: 'Waiver Saver: 3 days at $4,115.00 a day', amount_cents: 1234500 }]);
  const l = layout(f);
  const by = (b: string) => l.texts.find((t) => t.box === b)?.text;
  assert.equal(by('waiver-amount'), 'See 48');
  assert.equal(by('48'), '$12,360.00', 'box 48: the delivery and Waiver Saver');
  assert.ok(l.texts.filter((t) => t.box.startsWith('14-')).map((t) => t.text).join(' ').includes('Waiver Saver'));
  const boxes = ['39', '42-amount', 'cdw-amount', '43-amount', '44-amount', '45-amount', '46-amount', '47-amount', '48'].reduce((t, b) => t + cents(by(b)), 0);
  assert.equal(boxes, f.booking.subtotal_at_booking_cents);
});

test('every value fits inside the page and its box (shrunk, never past it)', () => {
  const f = withInsurerFees();
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
  assert.deepEqual(pink, ['15-from', '15-to', '21', '40', 'fuel-out']);
  assert.deepEqual(COVERS.filter((c) => c.color === 'white').map((c) => c.box).sort(), ['address', 'fuel-in', 'hst']);
  assert.deepEqual(COVERS.filter((c) => c.color === 'rose' || c.color === 'rule').map((c) => c.box).sort(), ['fuel-in-59', 'fuel-in-rule']);
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

// ---------------------------------------------------------------- a 31-day rental (the desk's report of October 30, 2026)
// 31 days at the monthly rate counted by the day ($2,997.43 / 30 x 31 = $3,097.35), the Protection Plan at $15.00 a day,
// delivery, a $500.00 card hold taken at pickup on October 1, 2026, a full tank out.
const LINES_31: Line[] = [
  { charge_type: 'rental_charge', description: 'Rental charge', amount_cents: 309735, hst_cents: 40266, stage: 'booking' },
  { charge_type: 'coverage_sold', description: 'CarmaCars Protection Plan', amount_cents: 46500, hst_cents: 6045, stage: 'booking' },
  { charge_type: 'delivery', description: 'Delivery', amount_cents: 5000, hst_cents: 650, stage: 'booking' }
];
function month(o: { deposit?: 'held' | 'pending'; fuel?: number | null; rate?: string; rental?: number } = {}): BlindSpotFacts {
  const f = sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' });
  const rental = o.rental ?? 309735;
  const lines = LINES_31.map((l) => (l.charge_type === 'rental_charge' ? { ...l, amount_cents: rental } : l));
  f.booking = { ...f.booking, pickup_at: '2026-10-01T15:00:00Z', return_at: '2026-11-01T15:00:00Z', billable_days: 31, rate_applied: o.rate ?? 'monthly',
    daily_rate_cents: 11900, weekly_rate_cents: 72000, monthly_rate_cents: 299743, rental_charge_cents: rental, deposit_cents: 50000, coverage_option: 3,
    subtotal_at_booking_cents: 361235, hst_at_booking_cents: 46961, total_due_at_booking_cents: 408196 };
  f.lines = lines.map(({ charge_type, description, amount_cents }) => ({ charge_type, description, amount_cents }));
  const x: AgreementExtra = { ...richFacts('pickup').x, lines, payments: [], swaps: [], insurer_policy: null,
    deposit: { amount_cents: 50000, pay_method: 'card', method: 'card_hold', paid_method: null, status: o.deposit ?? 'held', taken_at: o.deposit === 'pending' ? null : '2026-10-01T14:40:00Z',
      applied_cents: 0, released_cents: 0, held_back_cents: 0, card_hold_days: 7 } };
  x.pickup = o.fuel === undefined ? x.pickup : o.fuel === null ? null : { ...x.pickup!, fuel_pct: o.fuel };
  f.extra = { ...f.extra, more: x, coverage: { coverage_option: 3, insurer_name: null, policy_number: null, policy_expiry: null, card_issuer: null, card_last4: null, activation_ref: 'ACT-31' } };
  return f;
}
const box = (l: ReturnType<typeof layout>, b: string) => l.texts.find((t) => t.box === b)?.text;

test('31 days: box 35 is DAYS 31 @ the daily rate = the rental charge; box 14 says how; box 39 is the rate rows', () => {
  const l = layout(month());
  assert.equal(box(l, '35-count'), '31');
  assert.equal(box(l, '35-rate'), '$99.91', 'the rate column holds the rate ($3,097.35 / 31), never the whole charge');
  assert.equal(box(l, '35-amount'), '$3,097.35');
  assert.equal(box(l, '39'), '$3,097.35', 'sub total 39 = the rate rows');
  for (const b of ['36-amount', '37-amount', '37-rate', '38-amount']) assert.equal(box(l, b), undefined, `${b} blank`);
  const info = l.texts.filter((t) => t.box.startsWith('14-')).map((t) => t.text).join(' ');
  assert.ok(info.includes('Box 35: the monthly rate $2,997.43 / 30 x 31 days = $3,097.35, $99.91 a day rounded.'), info);
});

test('31 days: the money boxes add up (48 is delivery only; CDW is the plan; 50 = 13% of 49; 55 the total)', () => {
  const l = layout(month());
  assert.equal(box(l, 'cdw-rate'), '$15.00');
  assert.equal(box(l, 'cdw-amount'), '$465.00');
  assert.equal(box(l, '48'), '$50.00', 'pre adjustment: the charges with no box of their own (delivery), not the plan');
  assert.equal(box(l, '49'), '$3,612.35');
  assert.equal(cents(box(l, '49')), cents(box(l, '39')) + cents(box(l, 'cdw-amount')) + cents(box(l, '48')));
  assert.equal(box(l, '50'), '$469.61');
  assert.equal(cents(box(l, '50')), Math.round(cents(box(l, '49')) * 0.13), 'HST 50 = 13% x 49');
  assert.equal(box(l, '55'), '$4,081.96');
  assert.equal(cents(box(l, '55')), cents(box(l, '49')) + cents(box(l, '50')));
  const info = l.texts.filter((t) => t.box.startsWith('14-')).map((t) => t.text).join(' ');
  assert.ok(info.includes('Box 48: Delivery $50.00.'));
});

test('31 days: the deposit received and the day it was taken (59); before pickup, the deposit due, said so', () => {
  const held = layout(month());
  assert.equal(box(held, 'deposit-received'), '500.00', 'after the printed $');
  assert.equal(box(held, '59-m'), '10');
  assert.equal(box(held, '59-d'), '01');
  assert.equal(box(held, '56'), '$500.00');
  assert.ok(!held.texts.some((t) => t.box === 'deposit-due'));
  const due = layout(month({ deposit: 'pending' }));
  assert.equal(box(due, 'deposit-received'), undefined, 'nothing received yet');
  assert.equal(box(due, 'deposit-due'), '500.00 due at pickup');
  assert.equal(box(due, '59-m'), undefined);
  // cash taken: a deposit payment with no deposit row still counts
  const f = month({ deposit: 'pending' });
  f.extra.more = { ...f.extra.more!, payments: [{ purpose: 'deposit', kind: 'charge', method: 'cash', amount_cents: 50000, card_brand: null, card_last4: null, reference: null, at: '2026-10-02T16:00:00Z' }] };
  const cash = layout(f);
  assert.equal(box(cash, 'deposit-received'), '500.00');
  assert.equal(box(cash, '59-d'), '02');
});

test('the fuel gauges: covered, the check-out level in words, blank with no reading (never the printed "8 8 8 8 8")', () => {
  assert.equal(box(layout(month({ fuel: 100 })), 'fuel-out'), 'Full (100%)');
  assert.equal(box(layout(month({ fuel: 75 })), 'fuel-out'), '3/4 (75%)');
  const none = layout(month({ fuel: null }));
  assert.equal(box(none, 'fuel-out'), undefined);
  assert.equal(box(none, 'fuel-in'), undefined);
  assert.ok(none.covers.some((c) => c.box === 'fuel-out') && none.covers.some((c) => c.box === 'fuel-in'));
  assert.ok(!none.dots.some((d) => d.box.startsWith('fuel')));
  assert.equal(fuelText(0), 'Empty (0%)');
  assert.equal(fuelText(60), 'About 5/8 (60%)');
  assert.equal(fuelText(48), 'About 1/2 (48%)');
  assert.equal(fuelText(null), null);
});

test('the rate rows: the weeks or months row when that rate makes the charge; daily and weekend days and a hand-typed charge as an average', () => {
  const weeks = month({ rate: 'weekly', rental: 144000 });
  weeks.booking.billable_days = 14;
  const w = layout(weeks);
  assert.deepEqual([box(w, '36-count'), box(w, '36-rate'), box(w, '36-amount'), box(w, '39')], ['2', '$720.00', '$1,440.00', '$1,440.00']);
  const months = month({ rental: 299743 });
  months.booking.billable_days = 30;
  const m = layout(months);
  assert.deepEqual([box(m, '37-count'), box(m, '37-rate'), box(m, '37-amount')], ['1', '$2,997.43', '$2,997.43']);
  const typed = layout(month({ rate: 'manual', rental: 300000 }));
  assert.deepEqual([box(typed, '35-count'), box(typed, '35-rate'), box(typed, '35-amount')], ['31', '$96.77', '$3,000.00']);
  assert.ok(typed.texts.some((t) => t.box.startsWith('14-') && t.text.includes('Box 35: the rental charge agreed')));
  const mixed = sampleFacts({ mailing: MAILING, hst_number: null });
  mixed.booking = { ...mixed.booking, billable_days: 3, daily_days: 2, weekend_days: 1, rental_charge_cents: 33300 };
  mixed.lines = mixed.lines.map((l) => (l.charge_type === 'rental_charge' ? { ...l, amount_cents: 33300 } : l));
  const x = layout(mixed);
  assert.deepEqual([box(x, '35-count'), box(x, '35-rate'), box(x, '35-amount')], ['3', '$111.00', '$333.00']);
  assert.ok(x.texts.some((t) => t.box.startsWith('14-') && t.text.includes('Box 35: 2 days x $99.00 + 1 weekend days x $135.00 = $333.00, $111.00 a day.')));
});

test('the signature on the form: the renter in 16, 17 and 20 with the day signed; on a version drawn from the template too', async () => {
  const f = month();
  assert.equal(signedDay('2026-10-01T03:30:00Z'), '2026-09-30', 'the day in Toronto');
  const pages = async (bytes: Uint8Array) => read(bytes.slice()); // pdf.js takes the buffer it reads
  // the signed copy: the unsigned document, then the renter's signature and day
  const unsigned = await fillBlindSpot(await standIn(), layout(f), { company: { name: 'Ahmad' } });
  const signed = await fillBlindSpot(unsigned.bytes, { texts: [], dots: [], covers: [] }, { renter: { png: PNG }, signedOn: '2026-10-01T14:30:00Z' });
  const [s1] = await pages(signed.bytes);
  const day = s1!.items.find((i) => i.str === '2026-10-01');
  assert.ok(day && Math.abs(day.y - (PAGE_H - SIGNED_ON.date.y)) < 0.5 && Math.abs(day.x - SIGNED_ON.date.x) < 0.5, 'the day beside box 20');
  assert.ok(s1!.text.includes('SIGNED ON'));
  const images = async (bytes: Uint8Array) => {
    const doc = await PDFDocument.load(bytes);
    const xo = doc.getPage(0).node.Resources()?.lookupMaybe(PDFName.of('XObject'), PDFDict);
    return xo ? xo.keys().length : 0;
  };
  assert.equal(await images(unsigned.bytes), 0, 'unsigned: no signature image');
  assert.ok(await images(signed.bytes) >= 1, 'signed: the renter\'s drawn signature');
  // a version (as picked up): the template filled again, with the company's and the renter's signatures and the day
  const version = await fillBlindSpot(await standIn(), layout(f), { company: { name: 'Ahmad' }, renter: { png: PNG }, signedOn: '2026-10-01T14:30:00Z', drivers: [{ png: PNG }] });
  const [v1] = await pages(version.bytes);
  assert.ok(v1!.text.includes('2026-10-01') && v1!.text.includes('$99.91'));
  assert.ok(await images(version.bytes) >= 1);
  // no day without a signature
  const [n1] = await pages((await fillBlindSpot(await standIn(), layout(f), { signedOn: '2026-10-01T14:30:00Z' })).bytes);
  assert.ok(!n1!.text.includes('SIGNED ON'));
});

test('31 days on the stand-in: nothing is cut, and the values are where the form expects them', async () => {
  const out = await fillBlindSpot(await standIn(), layout(month()), { company: { name: 'Ahmad' } });
  assert.deepEqual(out.cut, []);
  const [p1] = await read(out.bytes);
  const near = (s2: string, x: number, yTop: number) => p1!.items.some((i) => i.str === s2 && Math.abs(i.y - (PAGE_H - yTop)) < 1 && Math.abs(i.x - x) < 80);
  assert.ok(near('$99.91', 415, 346), 'box 35 rate, right of the @');
  assert.ok(near('$3,097.35', 540, 346), 'box 35 amount');
  assert.ok(near('500.00', 374, 707.4), 'deposit received, after the printed $');
  assert.ok(near('Full (100%)', 326, 681.4), 'fuel out');
});
