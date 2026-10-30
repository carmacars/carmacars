// Both rental agreements, field by field (migration 0154, docs/changes/2026-10-24-agreement-accuracy.md): a made-up booking
// with two drivers, an insurance replacement rental, delivery, add-ons, a young driver, the Protection Plan and a cash
// deposit (rich-fixture.ts), rendered as CarmaCars' agreement and on Blind Spot's form (a stand-in of the private
// template), then as picked up and as returned. Every value is read back from the PDFs with pdf.js; the boxes of Blind
// Spot's form are checked where they are drawn. The certificate of completion is appended and read back too.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { agreementPdf } from './render.ts';
import { agreementBlocks, type SignatureRow } from './model.ts';
import { richFacts, RICH, type Stage } from './rich-fixture.ts';
import type { VersionHeader } from './extra.ts';
import { clauses, depositText } from './extra.ts';
import { layout, PAGE_H } from '../blindspot/layout.ts';
import { fillBlindSpot } from '../blindspot/fill.ts';
import { toBlindSpotFacts } from '../blindspot/facts.ts';
import { standIn } from '../blindspot/stand-in.ts';
import { appendCertificate, certificateLines, type Certificate } from '../signing/certificate.ts';

type Item = { str: string; x: number; y: number };
async function read(bytes: Uint8Array) {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const d = await pdfjs.getDocument({ data: bytes, verbosity: 0 }).promise;
  const pages: Array<{ items: Item[]; text: string }> = [];
  for (let i = 1; i <= d.numPages; i++) {
    const items = ((await (await d.getPage(i)).getTextContent()).items as Array<{ str: string; transform: number[] }>).filter((x) => x.str.trim()).map((x) => ({ str: x.str, x: x.transform[4]!, y: x.transform[5]! }));
    pages.push({ items, text: [...items].sort((a, b) => b.y - a.y || a.x - b.x).map((x) => x.str).join(' ').replace(/\s+/g, ' ') });
  }
  return pages;
}
const all = (pages: Awaited<ReturnType<typeof read>>) => pages.map((p) => p.text).join(' ');
const has = (text: string, list: string[], what: string) => { for (const s of list) assert.ok(text.includes(s), `${what} shows "${s}"`); };
const none = (text: string, what: string) => { for (const bad of [/\bundefined\b/, /\bnull\b/, /\bNaN\b/, /Invalid Date/, /\{\{/]) assert.doesNotMatch(text, bad, `${what}: ${bad}`); };
/** the value drawn nearest a box's place (x, y from the top of the page) */
const near = (items: Item[], s: string, x: number, yTop: number, tol = 3) => items.some((i) => i.str === s && Math.abs(i.y - (PAGE_H - yTop)) < tol && Math.abs(i.x - x) < 120);

const header = (stage: Stage): VersionHeader | null => stage === 'open' ? null : {
  version_no: stage === 'pickup' ? 2 : 3, previous_no: stage === 'pickup' ? 1 : 2, kind: stage, material: false, changes: [], countersigned_name: stage === 'pickup' ? 'Sam Staffer' : 'Riley Checker',
  original_signed_at: '2027-06-02T12:00:00Z', agreement_number: 'RA-20077' };

async function carmacars(stage: Stage) {
  const { f, x, bs } = richFacts(stage);
  const signatures: SignatureRow[] | undefined = stage === 'open' ? undefined : [{ party: 'Renter', name: 'Jordan Sample Renter', signature: 'Signed the agreement (signature on the signed original)', when: '' },
    { party: stage === 'pickup' ? 'CarmaCars (check-out)' : 'CarmaCars (check-in)', name: header(stage)!.countersigned_name!, signature: 'Countersigned electronically', when: 'Wed, Jun 16, 2027' }];
  const blocks = agreementBlocks(f, { privacyUrl: 'https://carmacars.ca/privacy', extra: x, insurer: bs.insurer, version: header(stage), signatures });
  return read(await agreementPdf(blocks, { title: 'Rental agreement', createdAt: new Date('2027-06-01T16:00:00Z'), footer: 'test' }));
}
async function blindspot(stage: Stage) {
  const { f, x, bs } = richFacts(stage);
  const l = layout(toBlindSpotFacts(f, bs, x));
  const out = await fillBlindSpot(await standIn(), l, { company: { name: 'Ahmad' } });
  return { pages: await read(out.bytes), l, cut: out.cut };
}

test('CarmaCars agreement: every party, the car, the dates, every price line, HST, total, the deposit and how it is held, coverage, the insurer, payment', async () => {
  const pages = await carmacars('open');
  const t = all(pages);
  none(t, 'opening');
  has(t, [
    // the renter and both drivers: name, address, date of birth, licence number, class, province, expiry
    'Jordan Sample Renter', '100 Example Street, Apt 1204, Toronto, ON M5H 2N2', 'S1234-56789-03314', 'Ontario', 'Mar 14, 2029', 'jordan.sample@example.test', '416-555-0142',
    'Casey Example Driver', '22 Sample Avenue, Toronto, ON M4M 1A1', 'E1234-56789-00701', 'Jul 1, 2028',
    // the car
    '2023 Mercedes-Benz C-Class C 300 4MATIC', 'Black', 'SMPL123', 'W1KAF4HB0PR000001', 'Fleet no.: F-07',
    // the dates and places
    'Jun 16, 2027', 'Jun 19, 2027', '100 Example Street, Toronto', 'Delivered by us', 'Picked up by us',
    // the rates, the kilometres, the late terms
    '3 daily days × $99', '200 km per day', '600 km', '$0.40 per km', 'grace period of 59 minutes', 'late fee of $25',
    // every price line, HST and the total
    'Rental charge', '$297.00', 'Young driver, 21 to 25', '$45.00', 'CarmaCars Protection Plan', '$60.00', 'Delivery', '$15.00', 'Baby seat', '$30.00',
    'Additional driver:', '$20.00', '$60.71', '$527.71',
    // the deposit and how it is held, the payment, the coverage, the insurance replacement
    '$1,000.00, cash, at pickup', 'by Interac e-Transfer', 'ref. ET-0001', 'the CarmaCars Protection Plan', '($60.00 for the rental)',
    'Example Mutual Insurance', 'CLM-0000-1234', 'Pat Adjuster', '416-555-0199', 'Authorized: 3 days at $99 a day', 'P-778899', '2019 Honda Civic, plate ABCD123',
    'VISA ending 4242', '$2,500'
  ], 'the opening agreement');
  assert.doesNotMatch(t, /30 days maximum/, 'no 30-day cap printed');
  assert.doesNotMatch(t, /a card hold for rentals of 7 days or less/, 'a cash deposit is not called a card hold');
  assert.ok(RICH.total === 52771);
});

test('CarmaCars agreement as picked up: the pickup record (time out, km out, fuel out, the car, damage, the report), countersigned by the staff member', async () => {
  const t = all(await carmacars('pickup'));
  none(t, 'pickup');
  has(t, ['Version 2 (as picked up)', 'Pickup record', 'Time out', 'Jun 16, 2027, 10:20 a.m.', 'Odometer out (K/M out)', '20,150 km', 'Fuel or charge out', '100% (full)',
    'Plate: SMPL123', 'VIN: W1KAF4HB0PR000001', 'D1: rear bumper, light scuff', 'A1B2C3D4', '19 photos', 'Sam Staffer', 'CarmaCars (check-out)', 'Countersigned electronically',
    'signature on the signed original', '$1,000.00, cash (held'], 'the pickup copy');
});

test('CarmaCars agreement as returned: time in, km in, driven, charged, fuel in, late, new damage, return charges, final totals and the balance', async () => {
  const t = all(await carmacars('return'));
  none(t, 'return');
  has(t, ['Version 3 (as returned)', 'Return record', 'Jun 19, 2027, 12:40 p.m.', '20,950 km', '800 km', '200 km at $0.40 per km', '75% (3/4)', '(out: 100% (full))',
    '2 h 40 min after the due-back time: 1 extra day charged', 'D2: front left wheel, curb rash', 'Riley Checker',
    'Kilometres over: 200 km at $0.40', '$80.00', 'Late return: 1 extra day', '$99.00', 'Late return fee', '$25.00', 'Fuel: 25% short', 'Fuel service fee', 'Cleaning', '$50.00',
    'HST on return charges', '$37.57', 'All charges before HST', '$756.00', '$98.28', '$854.28', 'Paid', '$527.71', 'Balance due from the Renter', '$326.57', '$700.00 returned'], 'the closing copy');
});

test('Blind Spot form at opening: every box with a value, the insurer and box 13, box 48 so the subtotal adds up, the deposit, the card', async () => {
  const { pages, l, cut } = await blindspot('open');
  const [p1] = pages; assert.ok(p1);
  assert.deepEqual(cut, [], 'no value is cut');
  none(p1.text, 'Blind Spot opening');
  has(p1.text, ['2967 DUNDAS ST W, UNIT 208B, TORONTO, ON M6P 1Z2', '79878 1234 RT0001', 'CC-10077', 'Jordan Sample Renter', '(416) 555-0142', '100 Example Street, Apt 1204', 'Toronto', 'M5H 2N2',
    '2003-03-14', 'S1234-56789-03314', 'Casey Example Driver', 'E1234-56789-00701', '2019 Honda Civic, plate ABCD123', 'CLM-0000-1234', 'Pat Adjuster, (416) 555-0199', 'Example Mutual Insurance',
    'P-778899', '2027-12-31', 'F-07', 'SMPL123', 'Mercedes-Benz', '2023 C-Class C 300 4MATIC', 'Jun 16, 2027 10:00 AM', '600 km', '200 km', '$0.40', '$99.00', '$297.00', '$45.00', '$60.00',
    '$65.00', '$467.00', '$60.71', '$527.71', '$1,000.00', '4242 (Visa)', '08/2029'], 'Blind Spot page 1');
  // box 48 carries delivery, the baby seat and the additional driver: 297 + 45 + 60 + 65 = 467, box 49
  assert.ok(near(p1.items, '$65.00', 577, 610), 'box 48 at its place');
  assert.ok(near(p1.items, '$467.00', 577, 630.5), 'box 49 at its place');
  assert.ok(near(p1.items, 'P-778899', 22, 468), 'box 13 at its place');
  // the age at pickup (24) and the due-back date in box 40
  assert.ok(p1.items.some((i) => i.str === '24'));
  assert.ok(!l.texts.some((t) => ['25', '27', '29', '31'].includes(t.box)), 'nothing in the boxes filled at return');
  assert.ok(p1.text.includes('Insurer authorized 3 days at $99.00/day.'));
});

test('Blind Spot form as picked up: time out, K/M out, fuel out, the cash deposit received', async () => {
  const { pages, l } = await blindspot('pickup');
  const [p1] = pages; assert.ok(p1);
  assert.ok(near(p1.items, 'Jun 16, 2027 10:20 AM', 475, 164), 'box 26: the actual time out');
  assert.ok(near(p1.items, '20,150 km', 475, 204.5), 'box 28: K/M out');
  assert.ok(l.texts.some((t) => t.box === 'fuel-out' && t.text === 'Full (100%)'), 'fuel out: full');
  assert.ok(l.texts.some((t) => t.box === 'deposit-received' && t.text === '1,000.00'), 'deposit received (after the printed $)');
  assert.ok(l.texts.some((t) => t.box === '59-m' && t.text === '06') && l.texts.some((t) => t.box === '59-d' && t.text === '16'), 'the day it was taken');
  assert.ok(p1.text.includes('Deposit $1,000.00 by cash.'));
});

test('Blind Spot form as returned: boxes 25 to 31, hours late, extra days, damages, fuel, the balance and what was paid', async () => {
  const { pages, l } = await blindspot('return');
  const [p1] = pages; assert.ok(p1);
  const box = (b: string) => l.texts.find((t) => t.box === b)?.text;
  assert.equal(box('25'), 'Jun 19, 2027 12:40 PM');
  assert.equal(box('27'), '20,950 km');
  assert.equal(box('29'), '800 km');
  assert.equal(box('30'), '600 km');
  assert.equal(box('31'), '200 km');
  assert.equal(box('33-count'), '200');
  assert.equal(box('33-amount'), '$80.00');
  assert.equal(box('34-count'), '3');
  assert.equal(box('34-amount'), '$25.00');
  assert.equal(box('38-count'), '1');
  assert.equal(box('38-amount'), '$99.00');
  assert.equal(box('39'), '$501.00');
  // 49 and 50: every charge but the return's fuel and cleaning, and 13% of it; 53 and 54 with their own HST
  assert.equal(box('49'), '$671.00');
  assert.equal(box('50'), '$87.23');
  assert.equal(box('53'), '$39.55');
  assert.equal(box('54'), '$56.50');
  assert.equal(box('55'), '$854.28');
  assert.equal(box('57'), '$326.57');
  assert.ok(l.dots.some((d) => d.box === '57-renter'), 'the balance is the renter\'s');
  assert.ok(l.texts.some((t) => t.box === 'fuel-in' && t.text === '3/4 (75%)'), 'fuel in: 3/4');
  assert.equal(box('paid'), '527.71');
  assert.equal(box('refund'), '700.00');
  for (const b of ['25', '27', '29', '31', '33-amount', '55', '57']) assert.ok(p1.text.includes(box(b)!), `box ${b} drawn`);
});

test('the key terms initialled are worded from the booking; the certificate of completion is appended with every step', async () => {
  const { f, x } = richFacts('open');
  const terms = clauses({ deductible_cents: f.booking.deductible_cents, deposit: depositText(x), card: 'VISA ending 4242', km_per_day: 200, km_total: 600, overage_cents_per_km: 40,
    grace_minutes: 59, late_fee_cents: 2500, coverage: 'the CarmaCars Protection Plan', booking_type: 'standard' });
  assert.deepEqual(terms.map((c) => c.code), ['damage', 'charges', 'fees', 'coverage', 'cancellation']);
  assert.match(terms[0]!.text, /\$2,500/);
  assert.match(terms[1]!.text, /\$1,000\.00, cash/);
  assert.match(terms[2]!.text, /600 km included \(200 km a day\), then \$0\.40/);
  const cert: Certificate = {
    document: 'Rental agreement RA-20077 for booking CC-10077', hashes: [{ label: 'CarmaCars rental agreement', sha256: 'a'.repeat(64) }], verifyUrl: 'https://carmacars.ca/verify', at: '2027-06-02T12:05:00Z',
    countersign: { name: 'Ahmad', at: '2027-06-02T12:05:00Z', text: 'Signed electronically for CarmaCars.' },
    signers: [{ signer_name: 'Jordan Sample Renter', signer_role: 'renter', method: 'in_person', collected_by: 'Sam Staffer', otp_channel: 'sms', otp_to: '***-***-0142', otp_verified_at: '2027-06-02T11:58:00Z',
      viewed_at: '2027-06-02T11:59:00Z', initials: { damage: { at: '2027-06-02T12:00:00Z' }, charges: { at: '2027-06-02T12:00:10Z' } }, consents: { esign: { at: '2027-06-02T12:01:00Z' }, card: { at: '2027-06-02T12:01:05Z' } },
      geo: { lat: 43.6532, lng: -79.3832, accuracy_m: 20 }, ip_address: '203.0.113.9', user_agent: 'Test Browser', signature_method: 'drawn', signed_at: '2027-06-02T12:02:00Z',
      licence: { licence_front: 'approved', licence_back: 'approved', selfie: 'approved', verified: true, expiry: '2029-03-14' },
      events: [{ at: '2027-06-02T11:57:00Z', kind: 'code_sent', detail: { channel: 'sms', to: '***-***-0142' }, ip_address: '203.0.113.9' }, { at: '2027-06-02T12:02:00Z', kind: 'signed', ip_address: '203.0.113.9' }] }]
  };
  const lines = certificateLines(cert).map((l) => l.text).join(' ');
  has(lines, ['Certificate of completion', 'a'.repeat(64), 'in person on a CarmaCars device, collected by Sam Staffer', 'one-time code by text to ***-***-0142', '2027-06-02 07:58:00 Toronto',
    'damage and the deductible', 'to card charges under the agreement', '43.6532, -79.3832, within 20 m', '203.0.113.9', 'Test Browser', 'front, back, selfie; identity verified',
    'Identity code sent (text to ***-***-0142)', 'https://carmacars.ca/verify'], 'the certificate');
  const { f: f2, x: x2, bs } = richFacts('open');
  const base = await agreementPdf(agreementBlocks(f2, { privacyUrl: 'https://carmacars.ca/privacy', extra: x2, insurer: bs.insurer }), { title: 't', createdAt: new Date(0), footer: 'test' });
  const withCert = await read(await appendCertificate(base, cert));
  const last = withCert[withCert.length - 1]!.text;
  assert.ok(last.includes('Certificate of completion') || withCert.some((p) => p.text.includes('Certificate of completion')), 'the certificate pages are at the end');
  assert.ok(withCert.length > (await read(base)).length, 'pages were added');

  // 0186: the code is optional; signed without it, the certificate says so (and never claims a code), the initials
  // cleared and redone are in the audit trail
  const noCode: Certificate = { ...cert, signers: [{ ...cert.signers[0]!, otp_channel: null, otp_to: null, otp_verified_at: null,
    events: [{ at: '2027-06-02T12:00:05Z', kind: 'initial_clear', detail: { code: 'damage' }, ip_address: '203.0.113.9' }, { at: '2027-06-02T12:02:00Z', kind: 'signed', ip_address: '203.0.113.9' }] }] };
  const nl = certificateLines(noCode).map((l) => l.text).join(' ');
  has(nl, ['Identity: not confirmed by a one-time code', 'Initials cleared for damage and the deductible', '203.0.113.9', 'Test Browser'], 'the certificate without a code');
  assert.ok(!nl.includes('one-time code by'), 'no code is claimed');
});

test('a long rental in periods: the length in all and the period this version covers (long rentals)', async () => {
  const { f, x, bs } = richFacts('open');
  const g = { ...f, booking: { ...f.booking, billable_days: 90 }, period: { seq: 2, of: 3, starts_at: '2027-07-01T14:00:00Z', ends_at: '2027-07-31T14:00:00Z', days: 30, amount_cents: 214_700 } };
  const text = all(await read(await agreementPdf(agreementBlocks(g, { privacyUrl: 'https://carmacars.ca/privacy', extra: x, insurer: bs.insurer }), { title: 't', createdAt: new Date(0), footer: 'test' })));
  has(text, ['90 days in all, in 3 periods, each with its own agreement', 'This agreement covers', 'Period 2 of 3', '(30 days)', 'with HST: $2,147'], 'the period');
  none(text, 'the period');
});
