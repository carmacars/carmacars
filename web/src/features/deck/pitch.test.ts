import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
// @ts-expect-error a plain .mjs module of the video scripts, no types
import { forbidden } from '../../../scripts/investor-video/forbidden.mjs';
import { ABOUT, BUSINESS_LINES, COMPETITORS, COVER, DEMAND, DIFFERENCE, EXAMPLE_AMOUNTS, FOOTNOTES, LEGAL_ENTITY, MODEL, PER_CAR, PLATFORM, RAISE, SLIDES, TERMS, monthlyInterest, optionOneRow, perCarRevenue } from './pitch.ts';

// The 2026 pitch deck (release 35): the owner's numbers, worked out the way the deck states them, and the investor rules
// (no fleet size, utilization, insurance premium or internal costs; only 18122211 Canada Inc. as the legal entity).
const f = forbidden as (t: string, w: string) => string[];
const all = [COVER.kicker, COVER.title, COVER.line, ...MODEL.supply, MODEL.lead, ...MODEL.extras, ...COMPETITORS.others.flatMap((x) => [x.title, x.text]), ...COMPETITORS.carmacars,
  ...DIFFERENCE, ...BUSINESS_LINES.flatMap((x) => [x.title, x.text]), ...PLATFORM.search.flatMap((x) => [x.big, x.text]), ...PLATFORM.ai, ...DEMAND.flatMap((x) => [x.big, x.text]), ABOUT.text, ...ABOUT.people.flatMap((p) => [p.name, p.role]), ...TERMS.flat(), ...Object.values(FOOTNOTES), ...SLIDES.map((s) => s.title)].join('\n');

test('ten slides, in the deck\'s order', () => {
  assert.deepEqual(SLIDES.map((s) => s.id), ['cover', 'model', 'lines', 'competitors', 'difference', 'platform', 'demand', 'per-car', 'ask', 'about']);
  assert.equal(COVER.title, 'Car rental, rebuilt for Ontario.');
  assert.equal(COVER.line, 'What goes around, drives around.');
});

test('the ask: $500,000, the use of funds adds up, no marketing line', () => {
  assert.equal(RAISE.amount, 500_000);
  assert.equal(RAISE.funds.reduce((s, x) => s + x.amount, 0), RAISE.amount);
  assert.deepEqual(RAISE.funds.map((x) => x.amount), [400_000, 50_000, 50_000]);
  assert.ok(!RAISE.funds.some((x) => /marketing/i.test(x.label)));
  assert.equal(Math.round(monthlyInterest(500_000, 10)), 4167);
  assert.equal(monthlyInterest(500_000, 15), 6250);
  assert.match(TERMS.map((t) => t[1]).join(' '), /\$4,167 to \$6,250 a month on \$500,000/);
  assert.match(TERMS.map((t) => t[1]).join(' '), /20 to 25% profit share from the cars this money puts on the road/);
  assert.match(FOOTNOTES.offer, /prospectus exemption/);
  assert.match(FOOTNOTES.offer, /signed agreement/);
});

test('per car: $112 a rented day, 25 days is $2,800, 3.2x, with the footnotes', () => {
  assert.equal(PER_CAR.perRentedDay, 112);
  assert.equal(perCarRevenue(), 2800);
  assert.equal(PER_CAR.multiplier, 3.2);
  assert.match(FOOTNOTES.illustration, /illustration, not a forecast/);
  assert.match(FOOTNOTES.internal, /internal and unaudited/);
});

test('five business lines, brokering included; the search footprint and the AI in the work', () => {
  assert.equal(BUSINESS_LINES.length, 5);
  assert.match(BUSINESS_LINES.map((x) => x.title).join(' '), /Brokering/);
  assert.match(BUSINESS_LINES.map((x) => x.title).join(' '), /Turo management/);
  assert.equal(PLATFORM.search[0]!.big, '18');
  assert.match(PLATFORM.ai.join(' '), /recorded, transcribed/);
  assert.match(PLATFORM.ai.join(' '), /intent score/);
  assert.match(PLATFORM.ai.join(' '), /Automatic answers/);
});

test('Option 1 examples are simple interest, paid monthly', () => {
  const r = optionOneRow(100_000);
  assert.equal(Math.round(r.monthlyLow * 100) / 100, 833.33);
  assert.equal(r.monthlyHigh, 1250);
  assert.equal(Math.round(r.yearlyLow), 10_000);
  assert.equal(EXAMPLE_AMOUNTS.at(-1), RAISE.amount);
});

test('nothing an investor must not see, and only the one legal entity', () => {
  assert.deepEqual(f(all, 'pitch'), []);
  assert.doesNotMatch(all, /\b\d+\s+(cars|vehicles)\b|utili[sz]ation|premium|internal costs?|margins?/i);
  assert.doesNotMatch(all.replaceAll(LEGAL_ENTITY, ''), /\bInc\b|\bCorp\b|\bLtd\b|Almash|Canada Inc/i);
  assert.match(all, /18122211 Canada Inc\./);
  assert.doesNotMatch(all, /[—–]/);
});

test('every investor page states these terms and no older one', () => {
  const read = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8');
  const view = read('../investor-model/View.tsx');
  assert.match(view, /TERMS/);
  assert.doesNotMatch(view, /offer_bps|on our current offer|months' notice/);
  const home = read('../../app/investor/page.tsx');
  assert.match(home, /RAISE\.option1/);
  assert.doesNotMatch(home, /deck_return_bps|Our current offer, a year/);
  assert.match(read('../../app/investor/deck/page.tsx'), /<PitchDeck /);
  assert.doesNotMatch(read('../investor-model/workbook.ts') + read('../investor-model/pdf.ts'), /on our current offer|months' notice|Lockup', `The first/);
});
