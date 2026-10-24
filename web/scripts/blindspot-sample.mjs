#!/usr/bin/env node
// One filled sample of Blind Spot's rental agreement from a template file, for .github/workflows/template-upload.yml:
// the made-up booking of the Admin's sample (web/src/features/blindspot/sample.ts, no real renter) with the real
// settings (the mailing address, the HST number, the representative), read back with pdf.js. Prints a JSON report
// (pages, bytes, SHA-256, which checks pass); never prints the template's or the sample's content.
//   node --experimental-strip-types scripts/blindspot-sample.mjs --template T.pdf --settings S.json [--signature P.png] --out O.pdf
// settings: app.rental_form_preview's result ({mailing, hst_number, rep}).
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { layout } from '../src/features/blindspot/layout.ts';
import { fillBlindSpot } from '../src/features/blindspot/fill.ts';
import { sampleFacts } from '../src/features/blindspot/sample.ts';

const arg = (k) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : undefined; };
const tpl = new Uint8Array(readFileSync(arg('template')));
const s = JSON.parse(readFileSync(arg('settings'), 'utf8'));
const sig = arg('signature') ? new Uint8Array(readFileSync(arg('signature'))) : null;
const facts = sampleFacts({ mailing: s.mailing, hst_number: s.hst_number ?? null });
const out = await fillBlindSpot(tpl, layout(facts), { company: sig ? { png: sig } : { name: s.rep?.name || 'Ahmad' }, title: 'BLINDSPOT-RA sample' });
writeFileSync(arg('out'), out.bytes);

const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
const doc = await pdfjs.getDocument({ data: out.bytes.slice(), verbosity: 0 }).promise;
const page = await doc.getPage(1);
const text = (await page.getTextContent()).items.map((i) => ('str' in i ? i.str : '')).join(' ');
const annots = (await page.getAnnotations()).map((a) => a.contentsObj?.str ?? '');
const street = String(s.mailing?.street ?? '').toUpperCase();
const checks = {
  old_address_removed: !annots.some((a) => /crockford/i.test(a)),
  mailing_address_top_left: !!street && text.includes(street),
  box_15_twice: text.split(String(s.mailing?.street ?? '\u0000')).length - 1 >= 2,
  hst_number: s.hst_number ? text.includes(s.hst_number) : 'not set: box 1 left blank',
  booking_filled: text.includes('CC-10001') && text.includes('Jordan Sample Renter'),
  representative: sig ? 'signature image' : `"${s.rep?.name || 'Ahmad'}" in a script hand`
};
const report = { pages: doc.numPages, bytes: out.bytes.length, sha256: createHash('sha256').update(out.bytes).digest('hex'), boxes_filled: out.drawn.length, shrunk: out.shrunk, cut: out.cut, removed_annotations: out.removedAnnotations, checks };
await doc.destroy();
console.log(JSON.stringify(report));
const ok = report.pages === 2 && checks.old_address_removed && checks.mailing_address_top_left && checks.box_15_twice && checks.booking_filled && checks.hst_number !== false && !out.cut.length;
process.exit(ok ? 0 : 1);
