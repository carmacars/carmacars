// The agreements as PDFs, read back with pdf.js (docs/changes/2026-10-23-form-fillers.md): the rental agreement, the
// owner's Enrollment Agreement and Form D, filled from records read from the database (tests/fixtures/agreements/facts.json,
// names made up). Every merge field is filled, the company is named as a party by its legal name, nothing breaks a VIN
// across lines, the signature lands in its column, and a table that runs onto a new page repeats its heading.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { agreementPdf } from './render.ts';
import { agreementBlocks, when, type AgreementFacts, type Block, type SignatureRow } from './model.ts';
import { documentBlocks, type OwnerAgreementFacts } from '../owner-agreement/model.ts';
import { witnessedBlocks, type WitnessedFacts } from '../owner-agreement/witnessed.ts';
import { screenFormBlocks, type ScreenFormFacts } from '../owner-agreement/screen-forms.ts';
import { companyParty, endSentence, phone } from '../../lib/format.ts';

const F = JSON.parse(readFileSync(new URL('../../../tests/fixtures/agreements/facts.json', import.meta.url), 'utf8')) as { rental: AgreementFacts; owner: OwnerAgreementFacts; form_a: ScreenFormFacts; form_d: WitnessedFacts };
// a drawn signature: 40 x 10 PNG
const PNG = Uint8Array.from(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAACgAAAAKCAYAAADGmhxQAAAALklEQVR4nGMQUEj4D8MMdARk2TvqWFrZO5COJUvTQDiWLDDqWFqBUcfSCpDjWAA6KT5ZaYCppQAAAABJRU5ErkJggg==', 'base64'));
const AT = '2026-10-23T15:42:00Z';
const COUNTERSIGN = 'Signed electronically for 18122211 Canada Inc., operating as CarmaCars, by Abbas Al-Mashita, Director, under a standing authorization dated October 16, 2026.';

type Item = { str: string; x: number; y: number };
async function read(bytes: Uint8Array) {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const d = await pdfjs.getDocument({ data: bytes, verbosity: 0 }).promise;
  const pages: Array<{ items: Item[]; text: string; images: Array<{ x: number; y: number; w: number; h: number }> }> = [];
  for (let i = 1; i <= d.numPages; i++) {
    const p = await d.getPage(i);
    const items = ((await p.getTextContent()).items as Array<{ str: string; transform: number[] }>).filter((x) => x.str.trim()).map((x) => ({ str: x.str, x: x.transform[4]!, y: x.transform[5]! }));
    const ops = await p.getOperatorList();
    const images: Array<{ x: number; y: number; w: number; h: number }> = [];
    let m = [1, 0, 0, 1, 0, 0]; const stack: number[][] = [];
    ops.fnArray.forEach((fn, k) => {
      if (fn === pdfjs.OPS.save) stack.push(m);
      else if (fn === pdfjs.OPS.restore) m = stack.pop() ?? [1, 0, 0, 1, 0, 0];
      else if (fn === pdfjs.OPS.transform) { const [a, b, c, dd, e, f] = ops.argsArray[k] as number[]; m = [m[0]! * a! + m[2]! * b!, m[1]! * a! + m[3]! * b!, m[0]! * c! + m[2]! * dd!, m[1]! * c! + m[3]! * dd!, m[0]! * e! + m[2]! * f! + m[4]!, m[1]! * e! + m[3]! * f! + m[5]!]; }
      else if (fn === pdfjs.OPS.paintImageXObject) images.push({ x: m[4]!, y: m[5]!, w: m[0]!, h: m[3]! });
    });
    // the page's text in reading order, lines joined with a space (a sentence wrapped over two lines reads whole); pdf-lib
    // draws word by word, so each item is one word
    const text = [...items].sort((a, b) => b.y - a.y || a.x - b.x).map((x) => x.str).join(' ').replace(/\s+/g, ' ');
    pages.push({ items, text, images });
  }
  return pages;
}
const noPlaceholders = (pages: Awaited<ReturnType<typeof read>>, what: string) => {
  const all = pages.map((p) => p.text).join(' ');
  for (const bad of [/\bundefined\b/, /\bnull\b/, /\bNaN\b/, /\[●\]/, /\{\{/, /\$-?0?\.?\b(?=\s|$)NaN/, /Invalid Date/]) assert.doesNotMatch(all, bad, `${what}: ${bad}`);
};
const signed = (party: string, name: string): SignatureRow => ({ party, name, signature: '', when: when(AT) });
const images = (blocks: Block[]) => {
  const m = new Map<number, Uint8Array>();
  for (const b of blocks) if (b.t === 'signatures') b.rows.forEach((r, i) => { if (r.signature === '') m.set(i, PNG); });
  return m;
};

test('the rental agreement: the legal company as a party, every field filled, the mobile as written, Toronto times, the signature in its column', async () => {
  const f = F.rental;
  const blocks = agreementBlocks(f, { privacyUrl: 'https://carmacars.ca/privacy', signatures: [signed('Renter', f.renter!.legal_name!), { party: 'CarmaCars', name: 'Abbas Al-Mashita', signature: COUNTERSIGN, when: when(AT) }] });
  const pages = await read(await agreementPdf(blocks, { title: 'Signed rental agreement', createdAt: new Date(AT), images: images(blocks), footer: 'CarmaCars rental agreement.' }));
  noPlaceholders(pages, 'rental');
  assert.match(pages[0]!.text, /This Agreement is between 18122211 Canada Inc\., operating as CarmaCars \("CarmaCars", "we", "us"\) and the Renter/);
  assert.match(pages[0]!.text, new RegExp(`Mobile: ${phone(f.renter!.mobile)}`));
  assert.doesNotMatch(pages[0]!.text, /Mobile: \+1/);
  assert.match(pages.map((p) => p.text).join(' '), new RegExp(when(f.booking.pickup_at).replace(/[.()]/g, '\\$&')), 'pickup in Toronto time');
  // the signature block: its heading's columns line up with the rows, and the drawn signature sits in its column
  const sp = pages.find((p) => p.items.some((i) => i.str === 'Electronic') && p.images.length)!;
  const head = (s: string) => sp.items.find((i) => i.str === s)!;
  const name = sp.items.find((i) => i.str === f.renter!.legal_name!.split(' ')[0])!;
  assert.ok(Math.abs(head('Name').x - name.x) < 1, `the Name heading (${head('Name').x}) over the name (${name.x})`);
  const sig = sp.images.find((im) => im.h <= 40)!;
  assert.ok(sig, 'the drawn signature is on the page');
  assert.ok(sig.x >= head('Electronic').x - 1 && sig.x + sig.w <= head('Date').x + 1, 'the signature inside the Electronic signature column');
  assert.ok(Math.abs(sig.y - name.y) < 45, 'on the renter\'s row');
});

test('the Enrollment Agreement: "18122211 Canada Inc., operating as CarmaCars and CarmaCars.ca", the owner\'s initials, the VIN on one line', async () => {
  const f = F.owner;
  const blocks = documentBlocks(f, 'enrollment', { owner: signed('Owner (corporation)', f.owner.signer_name), carmacars: { party: 'CarmaCars', name: 'Abbas Al-Mashita', signature: COUNTERSIGN, when: when(AT) }, initials: 'CL' });
  const pages = await read(await agreementPdf(blocks, { title: 'Vehicle Enrollment Agreement, signed', createdAt: new Date(AT), images: images(blocks), footer: 'CarmaCars Vehicle Enrollment Agreement.' }));
  noPlaceholders(pages, 'enrollment');
  assert.match(pages[0]!.text, /CarmaCars 18122211 Canada Inc\., operating as CarmaCars and CarmaCars\.ca CarmaCars notice address/, 'the company party row');
  const all = pages.map((p) => p.text).join(' ');
  assert.equal((all.match(/\bCL\b/g) ?? []).length, 3, 'the three initials');
  const vin = f.schedules[0]!.vin;
  assert.ok(pages.some((p) => p.items.some((i) => i.str.includes(vin))), 'the VIN whole on one line');
  assert.ok(pages.some((p) => p.images.length === 1), 'the owner\'s drawn signature');
  assert.doesNotMatch(all, /Holdings Ltd\. \(Northshore Holdings Ltd\.\)/, 'a corporation named once when its name is its legal name');
  assert.doesNotMatch(all, /\+1\d{10}/, 'phones as people write them');
});

test('Form D printed: the vehicle table keeps the VIN whole, a name ending with a full stop keeps one, the legal company named', async () => {
  const f = { ...F.form_d, owner: { ...F.form_d.owner, legal_name: 'Northshore Auto Holdings Ltd.' } };
  const pages = await read(await agreementPdf(witnessedBlocks(f), { title: 'Form D: limited power of attorney', createdAt: new Date(AT), brand: true, footer: 'CarmaCars. Form D.' }));
  noPlaceholders(pages, 'form D');
  const vin = f.vehicles[0]!.vin!;
  assert.ok(pages[0]!.items.some((i) => i.str === vin), `the VIN ${vin} in one piece`);
  assert.doesNotMatch(pages.map((p) => p.text).join(' '), /Ltd\.\./);
  assert.match(pages[0]!.text, /between 18122211 Canada Inc\., operating as CarmaCars, and Northshore Auto Holdings Ltd\. /);
  const a = screenFormBlocks({ ...F.form_a, owner: { ...F.form_a.owner, legal_name: 'Northshore Auto Holdings Ltd.' } });
  const ap = await read(await agreementPdf(a, { title: 'Form A', createdAt: new Date(AT), footer: 'CarmaCars Form A.' }));
  assert.doesNotMatch(ap.map((p) => p.text).join(' '), /Ltd\.\./);
});

test('a table that runs onto the next page repeats its heading there, and a heading never stays alone at the foot of a page', async () => {
  const rows = Array.from({ length: 70 }, (_, i) => [`Line ${i + 1}`, `$${(i + 1) * 10}.00`]);
  const pages = await read(await agreementPdf([{ t: 'title', text: 'Long table' }, { t: 'p', text: 'x '.repeat(900) }, { t: 'table', head: ['Item', 'Amount'], rows }], { title: 'Long', createdAt: new Date(AT), footer: 'Long.' }));
  const withRows = pages.filter((p) => p.items.some((i) => i.str === 'Line'));
  assert.ok(withRows.length >= 2, 'the table runs over two pages at least');
  for (const p of withRows) {
    const top = Math.max(...p.items.filter((i) => i.str === 'Line').map((i) => i.y));
    const h = p.items.find((i) => i.str === 'Item');
    assert.ok(h && h.y > top, 'the heading above the first row of the page');
  }
  for (const p of pages) if (p.items.some((i) => i.str === 'Item')) assert.ok(p.items.some((i) => i.str === 'Line'), 'no heading without a row under it');
});

test('formats: the company as a party, a phone, a sentence ending', () => {
  assert.equal(companyParty('18122211 Canada Inc.', 'CarmaCars'), '18122211 Canada Inc., operating as CarmaCars');
  assert.equal(companyParty(null, 'CarmaCars'), 'CarmaCars');
  assert.equal(phone('+14165550142'), '416-555-0142');
  assert.equal(phone('(416) 555 0142'), '416-555-0142');
  assert.equal(phone('+44 20 7946 0958'), '+44 20 7946 0958');
  assert.equal(endSentence('Northshore Auto Holdings Ltd.'), 'Northshore Auto Holdings Ltd.');
  assert.equal(endSentence('Olivia Tremblay'), 'Olivia Tremblay.');
});
