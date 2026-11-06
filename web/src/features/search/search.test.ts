// The site search (release 28, B4): the public list and its ranking.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PAGES, PORTALS, norm, rankItems, type Item } from './index-items.ts';

const ALL: Item[] = [...PORTALS, ...PAGES,
  { t: '2024 Mercedes-Benz C-Class', s: 'C300 4MATIC · Black', h: '/cars/mercedes-c300-black', g: 'cars', w: 'luxury sedan' },
  { t: 'Car rental in Markham', h: '/car-rental/markham', g: 'places' }];

test('an investor finds the investor portal sign in', () => {
  const r = rankItems(ALL, 'investor');
  assert.equal(r[0]!.h, '/investor');
  assert.ok(rankItems(ALL, 'investor sign in')[0]!.t.includes('Investor portal'));
});

test('an owner finds the owner portal; anyone finds sign in', () => {
  assert.equal(rankItems(ALL, 'owner portal')[0]!.h, '/owner');
  assert.equal(rankItems(ALL, 'login')[0]!.g, 'portals');
});

test('cars by make, model, trim or kind', () => {
  assert.equal(rankItems(ALL, 'mercedes')[0]!.g, 'cars');
  assert.equal(rankItems(ALL, 'c300')[0]!.g, 'cars');
  assert.ok(rankItems(ALL, 'luxury sedan').some((x) => x.g === 'cars'));
});

test('every word must match; accents and case do not matter', () => {
  assert.deepEqual(rankItems(ALL, 'mercedes markham'), []);
  assert.equal(norm('Crédit  CARD!'), 'credit card');
  assert.equal(rankItems(ALL, 'MARKHAM')[0]!.h, '/car-rental/markham');
  assert.deepEqual(rankItems(ALL, '   '), []);
});

test('the lists link only to this site, each once', () => {
  const hrefs = [...PORTALS, ...PAGES].map((i) => i.h);
  assert.ok(hrefs.every((h) => h.startsWith('/') && !h.startsWith('//')));
  const keys = [...PORTALS, ...PAGES].map((i) => `${i.h} ${i.t}`);
  assert.equal(new Set(keys).size, keys.length);
});
