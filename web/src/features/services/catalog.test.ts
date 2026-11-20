import assert from 'node:assert/strict';
import { test } from 'node:test';
import { promoCards, serviceCards, type ServiceFacts } from './catalog.ts';

const F: ServiceFacts = { brand: 'CarmaCars', city: 'Toronto', trackerOn: true, trackerFromCents: 1500, trackerAvailable: false, trackerNote: 'Shipping soon', deliveryFromCents: 7500, chauffeurFromCents: 9900,
  minAge: 18, licence: 'G2 or G', airports: [{ code: 'YYZ', name: 'Toronto Pearson Airport' }], coverageOptions: 3,
  addons: [{ code: 'phone_charger', name: 'Phone charger', price_cents: 500, pricing_unit: 'per_trip' }, { code: 'child_seat', name: 'Child seat', price_cents: 1500, pricing_unit: 'per_day' }, { code: 'flowers', name: 'Flowers', price_cents: 15000, pricing_unit: 'per_trip' }],
  landing: new Set(['monthly', 'weekly', 'insurance-replacement', 'rideshare', 'young-drivers', 'g2-licence', 'with-a-charger', 'with-flowers', 'with-child-seat', 'car-delivery', 'airport', 'insurance-included']) };

test('every service the owner listed has a card, the tracker first', () => {
  const cards = serviceCards(F);
  assert.deepEqual(cards.map((c) => c.key), ['trackers', 'owner', 'chauffeur', 'delivery', 'coverage', 'monthly', 'replacement', 'rideshare', 'young', 'addons', 'detailing', 'bodyshop']);
  assert.equal(cards[0]!.feature, true);
  assert.equal(cards[0]!.fact, 'From $15 a month per car · Shipping soon');
  assert.equal(cards[0]!.go, 'Join the waitlist');
  assert.equal(cards.find((c) => c.key === 'chauffeur')!.fact, 'From $99 an hour');
  assert.equal(cards.find((c) => c.key === 'delivery')!.fact, 'Delivered from $75');
  assert.equal(cards.find((c) => c.key === 'addons')!.fact, 'Charger $5 · Seats $15 a day');
  for (const c of cards) { assert.ok(c.href.startsWith('/')); assert.ok(c.line.length <= 130, `${c.key}: one line`); for (const m of c.more) assert.ok(m.href.startsWith('/')); }
});

test('a number the database does not have is left out, and a page that is not there is never linked', () => {
  const bare: ServiceFacts = { ...F, trackerFromCents: null, deliveryFromCents: null, chauffeurFromCents: null, addons: [], landing: new Set() };
  const cards = serviceCards(bare);
  assert.equal(cards.find((c) => c.key === 'chauffeur')!.fact, null);
  assert.equal(cards.find((c) => c.key === 'addons')!.fact, null);
  assert.equal(cards.find((c) => c.key === 'trackers')!.fact, 'Shipping soon');
  assert.doesNotMatch(JSON.stringify(cards), /\$\d/);
  assert.ok(!JSON.stringify(cards).includes('/car-rental/'), 'no landing page is linked when none exists');
  assert.equal(cards.find((c) => c.key === 'monthly')!.href, '/cars');
  // the tracker switched off: no card, and no link to its pages from the owner card
  const off = serviceCards({ ...F, trackerOn: false });
  assert.ok(!off.some((c) => c.key === 'trackers'));
  assert.ok(!JSON.stringify(off).includes('/trackers'));
});

test('the module of a page: the tracker and the owner program lead, the page\'s own service is left out, the rest turns with the page', () => {
  const a = promoCards(F, null, '/car-rental/toronto', 8);
  assert.equal(a.length, 8);
  assert.deepEqual(a.slice(0, 2).map((c) => c.key), ['trackers', 'owner']);
  assert.ok(!promoCards(F, 'chauffeur', '/chauffeur').some((c) => c.key === 'chauffeur'));
  assert.ok(!promoCards(F, 'trackers', '/trackers').some((c) => c.key === 'trackers'));
  const seen = new Set<string>();
  for (const city of ['toronto', 'mississauga', 'brampton', 'markham', 'vaughan', 'oakville', 'ajax', 'whitby', 'oshawa', 'milton', 'barrie', 'guelph', 'hamilton', 'pickering', 'aurora', 'newmarket']) for (const c of promoCards(F, null, `/car-rental/${city}`, 6)) seen.add(c.key);
  assert.equal(seen.size, serviceCards(F).length, 'across pages every service is linked');
  assert.deepEqual(promoCards(F, null, '/x', 4).map((c) => c.key), promoCards(F, null, '/x', 4).map((c) => c.key), 'the same page always shows the same cards');
});
