import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { combineEmails, contentRange, textContent } from './email-combine.ts';

const ROOT = path.resolve(import.meta.dirname, '../../..');
const tpl = (code: string, ext: 'html' | 'txt') => readFileSync(path.join(ROOT, 'emails/templates', `${code}.${ext}`), 'utf8');

test('combine: every template\'s content is found between its hero band and its help line', () => {
  for (const code of ['renter_booking_confirmed', 'renter_payment_receipt', 'renter_agreement_version', 'owner_invoice_voided']) {
    const r = contentRange(tpl(code, 'html'));
    assert.ok(r, code);
    assert.ok(r[1] > r[0], code);
  }
});

test('combine: one email with one subject, each part a section with its own button, one footer', () => {
  const parts = ['renter_booking_confirmed', 'renter_payment_receipt', 'renter_agreement_version'].map((c) => ({ subject: `Subject of ${c}`, html: tpl(c, 'html'), text: tpl(c, 'txt') }));
  const out = combineEmails('Update on your booking CC-10080: confirmed, receipt and agreement', parts);
  assert.equal(out.subject, 'Update on your booking CC-10080: confirmed, receipt and agreement');
  assert.equal((out.html.match(/<\/html>/g) ?? []).length, 1);
  assert.equal((out.html.match(/<body/g) ?? []).length, 1);
  assert.match(out.html, /2 of 3/);
  assert.match(out.html, /3 of 3/);
  assert.match(out.html, /Subject of renter_payment_receipt/);
  // the footer (company line) once
  const foot = tpl('renter_booking_confirmed', 'html').slice(contentRange(tpl('renter_booking_confirmed', 'html'))![1]);
  assert.ok(out.html.endsWith(foot));
  // each part's content is inside
  for (const c of ['renter_payment_receipt', 'renter_agreement_version']) {
    const h = tpl(c, 'html'); const r = contentRange(h)!;
    assert.ok(out.html.includes(h.slice(r[0], r[1])), c);
  }
  assert.match(out.text, /^CarmaCars/);
  assert.match(out.text, /1 of 3: Subject of renter_booking_confirmed/);
  assert.match(out.text, /3 of 3: Subject of renter_agreement_version/);
  assert.equal((out.text.match(/^-{40}$/gm) ?? []).length, 1);
});

test('combine: a lone email goes as it is', () => {
  const p = { subject: 'Receipt', html: tpl('renter_payment_receipt', 'html'), text: tpl('renter_payment_receipt', 'txt') };
  assert.deepEqual(combineEmails('ignored', [p]), p);
  assert.throws(() => combineEmails('x', []));
});

test('combine: a part in an unknown layout still goes, as its words', () => {
  const out = combineEmails('Two', [{ subject: 'A', html: tpl('renter_payment_receipt', 'html'), text: tpl('renter_payment_receipt', 'txt') },
    { subject: 'B', html: '<p>plain</p>', text: 'CarmaCars\n\n' + '='.repeat(40) + '\n\nHello <there>\n\n' + '-'.repeat(40) + '\nfoot' }]);
  assert.match(out.html, /Hello &lt;there&gt;/);
  assert.equal(textContent('a\n' + '='.repeat(40) + '\nmiddle\n' + '-'.repeat(40) + '\nend'), 'middle');
});
