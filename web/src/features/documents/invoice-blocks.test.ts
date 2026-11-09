// r35 UX (1108): the insurer invoice is issued as Blind Spot Car Rental, with every fee by name, the values aligned and how to
// pay; nothing in it (its text, its properties, its footer) says CarmaCars. Every name, email and number here is made up.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { agreementPdf } from '../agreement/render.ts';
import { insurerInvoiceBlocks, invoiceFooter, itemizeLines, payBlocks, type InvoiceCompany } from './invoice-blocks.ts';

const BS: InvoiceCompany = { brand: 'Blind Spot Car Rental', legal_name: '18122211 Canada Inc.', address: '1 Example Street, Toronto ON', hst_number: '000000000RT0001', phone: '555-0100', email: 'billing@blindspot.example.test' };
const facts = (x: Record<string, unknown> = {}) => ({
  title: 'Invoice INS-5001', final: true, status: 'sent', invoice_number: 'INS-5001', sent_at: '2026-11-08T15:00:00Z', claim_number: 'CL-4471', renter_name: 'Sam Example',
  booking_number: 'CC-10077', vehicle: '2024 Kia K5', period_start: '2026-11-01', period_end: '2026-11-05', amount_cents: 41700, hst_cents: 5421, total_cents: 47121, paid_cents: 0, balance_cents: 47121,
  insurer: { name: 'Example Mutual', contact: 'A. Adjuster', address: '2 Example Road', email: 'claims@insurer.example.test' },
  lines: [{ description: 'Rental charge, booking CC-10077, 4 day(s) authorized', amount_cents: 30000 }, { description: 'Fees charged at booking', amount_cents: 11700 }],
  fee_items: [{ description: 'Protection Plan', amount_cents: 6000 }, { description: 'Young driver, 21 to 25', amount_cents: 4000 }, { description: 'Delivery', amount_cents: 1700 }],
  pay: { account_name: 'Example Billing', institution: 'Example Bank', institution_number: '001', transit_number: '00011', account_number: '0001111', etransfer_email: 'pay@blindspot.example.test' },
  company: BS, ...x });

async function pdfText(bytes: Uint8Array): Promise<{ text: string; items: Array<{ str: string; x: number; y: number }>; info: Record<string, unknown> }> {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const d = await pdfjs.getDocument({ data: bytes, verbosity: 0 }).promise;
  const items: Array<{ str: string; x: number; y: number }> = [];
  for (let i = 1; i <= d.numPages; i++) {
    const p = await d.getPage(i);
    for (const it of (await p.getTextContent()).items as Array<{ str: string; transform: number[] }>) if (it.str.trim()) items.push({ str: it.str, x: it.transform[4]!, y: it.transform[5]! + (d.numPages - i) * 1000 });
  }
  const info = ((await d.getMetadata()).info ?? {}) as Record<string, unknown>;
  return { text: [...items].sort((a, b) => b.y - a.y || a.x - b.x).map((x) => x.str).join(' ').replace(/\s+/g, ' '), items, info };
}

test('the insurer invoice says Blind Spot Car Rental and the legal entity, never CarmaCars (text, properties, footer)', async () => {
  const f = facts();
  const bytes = await agreementPdf(insurerInvoiceBlocks(f), { title: f.title, createdAt: new Date('2026-11-08T15:00:00Z'), brand: true, logo: null, valuesRight: true,
    wordmark: BS.brand, author: BS.brand, footer: invoiceFooter(f) });
  const r = await pdfText(bytes);
  assert.doesNotMatch(r.text, /carma/i);
  assert.doesNotMatch(JSON.stringify(r.info), /carma/i);
  assert.doesNotMatch(Buffer.from(bytes).toString('latin1'), /carma/i, 'nothing in the file says CarmaCars');
  assert.match(r.text, /BLIND SPOT CAR RENTAL/);
  assert.match(r.text, /18122211 Canada Inc\./);
  assert.doesNotMatch(r.text, /Preview/);
});

test('every fee by name instead of "Fees charged at booking", with the totals and how to pay', async () => {
  const f = facts();
  const r = await pdfText(await agreementPdf(insurerInvoiceBlocks(f), { title: f.title, createdAt: new Date(0), brand: true, valuesRight: true, wordmark: BS.brand, author: BS.brand, footer: invoiceFooter(f) }));
  for (const fee of ['Protection Plan', 'Young driver, 21 to 25', 'Delivery', 'Subtotal', 'HST', 'Total', 'Paid', 'Balance due', 'Direct deposit', 'Transit number', 'Interac e-Transfer', 'pay@blindspot.example.test'])
    assert.ok(r.text.includes(fee), fee);
  assert.doesNotMatch(r.text, /Fees charged at booking/);
});

test('the claim number sits in the value column like every other value (right-aligned)', async () => {
  const f = facts();
  const r = await pdfText(await agreementPdf(insurerInvoiceBlocks(f), { title: f.title, createdAt: new Date(0), brand: true, valuesRight: true, wordmark: BS.brand, footer: invoiceFooter(f) }));
  const right = (str: string) => { const it = r.items.find((i) => i.str === str); assert.ok(it, str); return it!.x; };
  // right-aligned values end at the same edge: a longer value starts further left
  assert.ok(right('CL-4471') > right('CC-10077') - 1, 'the claim number in the value column');
  assert.ok(right('CL-4471') > 300, 'not in the label column');
});

test('itemized only when the fees add up to the line; otherwise a plain "Other charges at booking"', () => {
  assert.deepEqual(itemizeLines([{ description: 'Fees charged at booking', amount_cents: 500 }], [{ description: 'Delivery', amount_cents: 1700 }]), [['Other charges at booking', 500]]);
  assert.deepEqual(itemizeLines([{ description: 'Fees charged at booking (delivery and pickup up to $100)', amount_cents: 1700 }], [{ description: 'Delivery', amount_cents: 1700 }]), [['Delivery', 1700]]);
});

test('how to pay: an empty section is left out; nothing at all, no heading', () => {
  assert.deepEqual(payBlocks({}, 'INS-1'), []);
  const only = payBlocks({ etransfer_email: 'pay@example.test' }, 'INS-1');
  assert.equal(only.filter((b) => b.t === 'table').length, 1);
  assert.ok(JSON.stringify(only).includes('Invoice INS-1'));
});

test('a draft says so in the footer; an issued invoice has no Draft and no Preview', () => {
  assert.equal(invoiceFooter({ ...facts(), status: 'draft', final: false }), 'Blind Spot Car Rental. Invoice INS-5001. Draft: not yet issued.');
  assert.equal(invoiceFooter(facts()), 'Blind Spot Car Rental. Invoice INS-5001.');
});
