import assert from 'node:assert/strict';
import { test } from 'node:test';
import { availability, ctaLabel, featureIcon, installSentence, priceSentence, productAnswer, productFaq, tierFor, tierLabel, TRACKER_PATHS, trackerIntents, type TrackerFacts } from './pages.ts';
import { negativeHits } from '../seo/copy-lint.ts';
import { similarity } from '../seo/copy.ts';

const F: TrackerFacts = { name: 'CarmaCars GPS tracker', brand: 'CarmaCars', city: 'Toronto', installCents: 15000, available: false, launchNote: 'Shipping soon', hst: '13%',
  tiers: [{ from_cars: 1, to_cars: 2, monthly_cents: 2500 }, { from_cars: 3, to_cars: 9, monthly_cents: 2000 }, { from_cars: 10, to_cars: null, monthly_cents: 1500 }],
  features: [{ title: 'Live GPS location', text: 'x' }, { title: 'Kill switch (engine shut-off)', text: 'x' }] };

test('the price by number of cars, as the Owner Program sets it', () => {
  assert.equal(tierFor(F.tiers, 1)?.monthly_cents, 2500);
  assert.equal(tierFor(F.tiers, 2)?.monthly_cents, 2500);
  assert.equal(tierFor(F.tiers, 3)?.monthly_cents, 2000);
  assert.equal(tierFor(F.tiers, 9)?.monthly_cents, 2000);
  assert.equal(tierFor(F.tiers, 10)?.monthly_cents, 1500);
  assert.equal(tierFor(F.tiers, 0)?.monthly_cents, 2500, 'never below one car');
  assert.deepEqual(F.tiers.map(tierLabel), ['1 to 2 cars', '3 to 9 cars', '10 cars or more']);
  assert.equal(priceSentence(F), '$25 a month per car for 1 to 2 cars, $20 for 3 to 9 cars and $15 for 10 cars or more');
  assert.equal(installSentence(F), '$150 once per car to install');
});

test('while trackers are not in hand every page offers the waitlist and never says in stock', () => {
  assert.equal(ctaLabel(F), 'Join the waitlist');
  assert.match(availability(F), /Shipping soon: join the waitlist or pre-order/);
  const all = [productAnswer(F), ...productFaq(F).flatMap((q) => [q.question, q.answer]),
    ...trackerIntents(F).flatMap((i) => [i.title, i.h1, i.answer, i.section.h, i.section.p, ...(i.section.steps ?? []).flat(), ...(i.section.points ?? []).flatMap((p) => [p.title, p.text]),
      i.compare.caption, ...i.compare.head, ...i.compare.rows.flat(), ...i.faq.flatMap((q) => [q.question, q.answer])])].join('\n');
  assert.doesNotMatch(all, /in stock|available now|ships today|order today|buy now/i);
  assert.match(productFaq(F).find((q) => /today/.test(q.question))!.answer, /waitlist or pre-order/);
  // when the setting is turned on, the same pages take orders
  const on = { ...F, available: true };
  assert.equal(ctaLabel(on), 'Order a tracker');
  assert.match(availability(on), /Installs are open/);
});

test('every intent page is its own page: its own address, title, heading, answer, section, table and questions', () => {
  const pages = trackerIntents(F);
  assert.equal(pages.length, 7);
  for (const k of ['slug', 'title', 'h1', 'answer'] as const) assert.equal(new Set(pages.map((p) => p[k])).size, pages.length, `${k} repeats`);
  assert.equal(new Set(pages.map((p) => p.section.h)).size, pages.length);
  assert.equal(new Set(pages.map((p) => p.compare.caption)).size, pages.length);
  const questions = pages.flatMap((p) => p.faq.map((q) => q.question));
  assert.ok(new Set(questions).size >= questions.length - 2, 'the questions are the page\'s own');
  for (const p of pages) {
    assert.match(p.slug, /^[a-z0-9-]+$/);
    assert.ok(p.faq.length >= 3, p.slug);
    assert.ok(p.title.length <= 70, `${p.slug}: the title fits a search result (${p.title.length})`);
    assert.ok(p.answer.length > 120 && p.answer.length < 520, `${p.slug}: an answer a person reads in one breath`);
    for (const r of p.compare.rows) assert.equal(r.length, p.compare.head.length, `${p.slug}: a table row has a cell for every column`);
    assert.ok(TRACKER_PATHS.includes(`/trackers/${p.slug}`), `${p.slug} is in the sitemap list`);
  }
  for (const want of ['kill-switch-for-car', 'gps-tracker-for-rental-car', 'anti-theft-tracker-toronto', 'fleet-tracking', 'turo-host-gps-tracker']) assert.ok(pages.some((p) => p.slug === want), want);
});

test('prices on the pages come from the settings, never typed', () => {
  const other: TrackerFacts = { ...F, installCents: 19900, tiers: [{ from_cars: 1, to_cars: 4, monthly_cents: 3000 }, { from_cars: 5, to_cars: null, monthly_cents: 1800 }] };
  const text = JSON.stringify([productAnswer(other), productFaq(other), trackerIntents(other)]);
  assert.doesNotMatch(text, /\$25|\$20\b|\$15\b|\$150/);
  assert.match(text, /\$30 a month per car for 1 to 4 cars and \$18 for 5 cars or more/);
  assert.match(text, /\$199/);
  // no tiers and no install price: the page says quoted, never a made-up number
  const none: TrackerFacts = { ...F, tiers: [], installCents: null };
  assert.match(productAnswer(none), /quoted for your cars/);
  assert.doesNotMatch(JSON.stringify(trackerIntents(none)), /\$\d/);
});

test('the copy follows the positive-copy rule and names Turo only with the not-affiliated sentence', () => {
  const pages = trackerIntents(F);
  for (const p of pages) for (const s of [p.answer, p.section.p, ...p.faq.map((q) => q.answer)]) assert.deepEqual(negativeHits(s), [], `${p.slug}: ${s}`);
  const turo = pages.find((p) => p.slug === 'turo-host-gps-tracker')!;
  assert.match(turo.answer, /not affiliated with Turo/);
  assert.match(turo.faq.find((q) => /Turo product/.test(q.question))!.answer, /not affiliated with or endorsed by Turo/);
  for (const p of pages.filter((x) => x !== turo)) assert.doesNotMatch(p.answer + p.h1 + p.title, /Turo/, p.slug);
});

test('each feature gets its icon', () => {
  assert.equal(featureIcon('Kill switch (engine shut-off)'), 'power');
  assert.equal(featureIcon('Remote lock and door release'), 'lock');
  assert.equal(featureIcon('Tolls and tickets go to the driver'), 'receipt');
  assert.equal(featureIcon('Live GPS location'), 'pin');
});

test('the intent pages are not copies of each other: the site\'s own similarity measure, well under the 50% the search copy allows', () => {
  const own = (p: ReturnType<typeof trackerIntents>[number]) => [p.answer, p.section.p, ...(p.section.steps ?? []).flat(), ...(p.section.points ?? []).flatMap((x) => [x.title, x.text]), ...p.faq.flatMap((q) => [q.question, q.answer])].join(' ');
  const pages = trackerIntents(F);
  for (const a of pages) for (const b of pages) if (a !== b) assert.ok(similarity(own(a), own(b)) < 0.25, `${a.slug} repeats ${b.slug}: ${Math.round(similarity(own(a), own(b)) * 100)}%`);
});
