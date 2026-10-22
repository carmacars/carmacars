import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CHANNELS, STOP_LINE, SMS_SAMPLE, isChannel, isGsm, nowWords, quietWords, renderSms, smsTemplateProblem, whyNotWords } from './alerts.ts';

// Text alerts (migration 0096): every text template of the migration is short, has no long dash, names CarmaCars,
// links to its page and fits two texts with a long car name, the link and the STOP line; the renderer tidies like the
// database's; the words of each screen.
const sql = readFileSync(new URL('../../../../supabase/migrations/0096_text_alerts.sql', import.meta.url), 'utf8');
const block = sql.slice(sql.indexOf('insert into sms_templates'), sql.indexOf('on conflict (code) do nothing'));
const TEMPLATES = [...block.matchAll(/\('([a-z_]+)', '((?:[^']|'')+)', '((?:[^']|'')+)', (true|false), (\d+)\)/g)]
  .map((m) => ({ code: m[1]!, label: m[2]!.replace(/''/g, "'"), body: m[3]!.replace(/''/g, "'"), urgent: m[4] === 'true' }));
const GENERIC = /sms_generic_text text not null default '((?:[^']|'')+)'/.exec(sql)![1]!.replace(/''/g, "'");
const LONG_DASH = /[–—]/;
const segs = (s: string) => (s.length <= 160 ? 1 : Math.ceil(s.length / 153));

test('the migration has a text for every notification the owner listed', () => {
  const codes = new Set(TEMPLATES.map((t) => t.code));
  for (const c of ['renter_request_received', 'renter_offer_ready', 'renter_booking_confirmed', 'renter_payment_receipt', 'renter_payment_failed',
    'renter_deposit_declined', 'renter_deposit_released', 'renter_booking_reminder', 'renter_return_reminder', 'renter_extension_approved',
    'renter_extension_confirmed', 'renter_late_return_first', 'renter_late_return_final', 'renter_agreement_ready', 'renter_identity_needed',
    'renter_coverage_needed', 'renter_review_request', 'owner_payout_sent', 'owner_statement_ready', 'owner_fee_invoice', 'owner_agreement_ready',
    'owner_new_booking', 'investor_statement_ready', 'person_document_to_sign']) assert.ok(codes.has(c), `no text for ${c}`);
  assert.ok(TEMPLATES.length >= 40, `parsed ${TEMPLATES.length} templates`);
  assert.equal(new Set(TEMPLATES.map((t) => t.code)).size, TEMPLATES.length, 'one template per code');
});

test('every template: no long dash, names CarmaCars, has the link, short, plain characters', () => {
  for (const t of [...TEMPLATES, { code: 'generic', body: GENERIC, label: 'generic', urgent: false }]) {
    assert.equal(smsTemplateProblem(t.body), null, `${t.code}: ${smsTemplateProblem(t.body)}`);
    assert.ok(!LONG_DASH.test(t.body) && !LONG_DASH.test(t.label), `${t.code}: long dash`);
    assert.ok(!/Carma[ -]Cars|Carmacars|CARMACARS/.test(t.body), `${t.code}: brand spelled CarmaCars`);
    const fixed = t.body.replace(/\{\{[a-z_]+\}\}/g, '');
    assert.ok(fixed.length <= 110, `${t.code}: ${fixed.length} characters of fixed text (110 at most, so the values fit)`);
    assert.ok(isGsm(t.body), `${t.code}: only plain text characters (a curly quote makes every text 70 characters)`);
  }
});

test('rendered with long sample values and the STOP line, every text fits in two texts; most in one without the STOP line', () => {
  let one = 0;
  for (const t of TEMPLATES) {
    const out = renderSms(t.body, SMS_SAMPLE);
    assert.ok(!/\{\{|\}\}/.test(out), `${t.code}: a placeholder left: ${out}`);
    assert.ok(out.includes(SMS_SAMPLE.link!), `${t.code}: the link`);
    assert.ok(segs(`${out} ${STOP_LINE}`) <= 2, `${t.code}: ${out.length + STOP_LINE.length + 1} characters with the STOP line`);
    assert.ok(!LONG_DASH.test(out));
    if (segs(out) === 1) one++;
  }
  assert.ok(one / TEMPLATES.length >= 0.6, `${one} of ${TEMPLATES.length} fit in one text`);
});

test('the renderer tidies empty values like the database', () => {
  assert.equal(renderSms('CarmaCars: refund {{refund_amount}}. Details: {{link}}', { link: 'https://carmacars.ca/x' }), 'CarmaCars: refund. Details: https://carmacars.ca/x');
  assert.equal(renderSms('CarmaCars: {{a}} ({{b}}), ok {{link}}', { a: 'A', link: 'L' }), 'CarmaCars: A, ok L');
  assert.equal(renderSms('CarmaCars — hi {{link}}', { link: 'L' }), 'CarmaCars, hi L');
});

test('templates: what an Admin may not save', () => {
  assert.match(smsTemplateProblem('Your offer is ready {{link}}')!, /CarmaCars/);
  assert.match(smsTemplateProblem('CarmaCars: your offer is ready')!, /link/);
  assert.match(smsTemplateProblem('CarmaCars — {{link}}')!, /long dashes/);
  assert.match(smsTemplateProblem(`CarmaCars ${'x'.repeat(320)} {{link}}`)!, /320/);
  assert.match(smsTemplateProblem('  ')!, /Write/);
});

test('the words: channels, why texts are not going, now, quiet hours', () => {
  assert.deepEqual(CHANNELS, ['email', 'text', 'both']);
  assert.ok(isChannel('text') && !isChannel('sms'));
  assert.match(whyNotWords('opted_out', '(289) 312-5991')!, /START to \(289\) 312-5991/);
  assert.match(whyNotWords('us_waiting', null, 'they')!, /A2P 10DLC/);
  assert.match(whyNotWords('no_verified_phone')!, /Verify your mobile number/);
  assert.equal(whyNotWords(null), null);
  assert.equal(nowWords({ channel: 'both', wanted: 'both', email: 'a@b.c' }), 'We text and email you.');
  assert.match(nowWords({ channel: 'text', wanted: 'text', email: null }), /Documents are still emailed/);
  assert.equal(quietWords(21, 8), 'No texts from 9 pm to 8 am unless it is urgent; they wait until 8 am.');
  for (const w of [whyNotWords('opted_out'), whyNotWords('off'), whyNotWords('not_canada'), nowWords({ channel: 'email', wanted: 'email', email: 'x' }), quietWords()]) assert.ok(!LONG_DASH.test(w!));
});
