import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { cardFaq, checkedOn, daysLimit, filterCards, NO_FILTER, reaching, valueLimit, type CardRow } from './cards.ts';

// The credit card coverage list (0131): its words and filters, and the rules of the page that shows it.
const row = (o: Partial<CardRow> = {}): CardRow => ({
  id: 'x', country: 'CA', issuer: 'Example Bank', card: 'Travel Visa Infinite', coverage: 'primary', max_msrp_cents: 6500000, value_note: null, max_days: 48,
  exclusions: 'Vans, trucks, exotic vehicles (for example Porsche)', conditions: 'Decline the CDW', car_sharing: null, note: null, guide_url: 'https://example.test/g.pdf',
  source_url: null, issuer_checked: true, last_checked: '2026-10-23', sort_order: 0, is_active: true, ...o
});
const rows = [
  row({ id: 'a', issuer: 'Alpha', card: 'Gold', max_msrp_cents: 6500000 }),
  row({ id: 'b', issuer: 'Beta', card: 'Platinum', max_msrp_cents: 8500000, coverage: 'ask' }),
  row({ id: 'c', issuer: 'Gamma', card: 'Privilege', max_msrp_cents: 10000000 }),
  row({ id: 'd', issuer: 'Delta', card: 'Basic', coverage: 'none', max_msrp_cents: null, max_days: null }),
  row({ id: 'e', issuer: 'Echo', card: 'World', max_msrp_cents: null, value_note: 'Cars worth more than $65,000 at the time of loss are not covered.', max_days: 31 }),
  row({ id: 'f', country: 'US', issuer: 'Foxtrot', card: 'Reserve', max_msrp_cents: 7500000, max_days: 31 })
];

test('the limits in words: MSRP, the document\'s own words, none', () => {
  assert.equal(valueLimit(rows[0]!), '$65,000 MSRP');
  assert.equal(valueLimit(rows[2]!), '$100,000 MSRP');
  assert.equal(valueLimit(rows[3]!), 'None');
  assert.equal(valueLimit(rows[4]!), 'Cars worth more than $65,000 at the time of loss are not covered.');
  assert.equal(valueLimit(row({ max_msrp_cents: null })), 'Not stated');
  assert.equal(daysLimit(rows[0]!), '48 days');
  assert.equal(daysLimit(rows[3]!), 'None');
  assert.equal(daysLimit(row({ max_days: null })), 'Not stated');
  assert.equal(checkedOn('2026-10-23'), 'October 23, 2026');
  assert.equal(checkedOn(null), '');
});

test('filters: words, country, primary only, and the car value a card reaches', () => {
  assert.deepEqual(filterCards(rows, NO_FILTER).map((c) => c.id), ['a', 'b', 'c', 'd', 'e', 'f']);
  assert.deepEqual(filterCards(rows, { ...NO_FILTER, q: 'gamma' }).map((c) => c.id), ['c']);
  assert.deepEqual(filterCards(rows, { ...NO_FILTER, q: 'porsche alpha' }).map((c) => c.id), ['a'], 'every word, in the card or its exclusions');
  assert.deepEqual(filterCards(rows, { ...NO_FILTER, country: 'US' }).map((c) => c.id), ['f']);
  assert.deepEqual(filterCards(rows, { ...NO_FILTER, primary: true }).map((c) => c.id), ['a', 'c', 'e', 'f']);
  // a card with no stated MSRP limit, or no coverage, never counts as reaching a value
  assert.deepEqual(filterCards(rows, { ...NO_FILTER, value: '85000' }).map((c) => c.id), ['b', 'c']);
  assert.deepEqual(filterCards(rows, { ...NO_FILTER, value: '100000' }).map((c) => c.id), ['c']);
  assert.deepEqual(reaching(rows, 85000).map((c) => c.id), ['b', 'c']);
});

test('the questions: counted from the list, never a promise, CarmaCars decides no claim', () => {
  const faq = cardFaq(rows);
  assert.equal(faq.length, 5);
  const value = faq.find((q) => q.question === 'What car value do credit cards cover?')!.answer;
  assert.match(value, /1 Canadian card stops at \$65,000 and 1 Canadian card stops at \$85,000; Gamma Privilege reaches \$100,000/);
  assert.match(faq.at(-1)!.answer, /CarmaCars does not decide claims and is not an insurer/);
  for (const q of faq) {
    assert.doesNotMatch(q.question + q.answer, /[—]| – /, 'no dashes');
    assert.doesNotMatch(q.answer, /you are covered|guaranteed|always covered/i, 'no promise');
    // the Protection Plan is never insurance or coverage
    assert.doesNotMatch(q.answer, /Protection Plan (insurance|coverage)/);
  }
});

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..');
const read = (p: string) => readFileSync(path.join(ROOT, p), 'utf8');

test('the page: the issuer confirms, CarmaCars decides no claim, the checklist, linked from requirements, the coverage choice, the FAQ and llms', () => {
  const page = read('web/src/app/credit-card-rental-coverage/page.tsx');
  assert.match(page, /Confirm with your card issuer before you rent/);
  assert.match(page, /CarmaCars does not decide claims/);
  for (const s of ['Pay the whole rental with that card', 'Decline other damage waivers only if your card', 'Bring proof of coverage']) assert.ok(page.includes(s), s);
  assert.doesNotMatch(page, /18122211|Canada Inc/);
  assert.match(read('web/src/app/requirements/page.tsx'), /href="\/credit-card-rental-coverage"/);
  assert.match(read('web/src/features/booking/RequestWizard.tsx'), /\/credit-card-rental-coverage/);
  assert.match(read('web/src/features/portal/CoverageSection.tsx'), /\/credit-card-rental-coverage/);
  assert.match(read('web/scripts/content/site-content.json'), /Which credit cards include rental car coverage\?/);
  assert.match(read('web/src/features/seo/facts.ts'), /path: '\/credit-card-rental-coverage'/);
  assert.match(read('web/src/features/seo/sitemap.ts'), /'\/credit-card-rental-coverage'/);
  assert.match(read('supabase/migrations/0131_card_coverage.sql'), /'question', 'Which credit cards include rental car coverage\?'/);
});
