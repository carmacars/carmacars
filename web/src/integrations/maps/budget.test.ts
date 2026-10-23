// Unit tests for the daily Google cap (0113): the budget is checked before each Google call, and over budget (or with
// the budget unreadable) the answer is the no-Google one.
//   node --test --experimental-strip-types src/integrations/maps/budget.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { budgetedMaps, type MapsSku } from './budget.ts';
import { googleMaps } from './google.ts';
import { fakeMaps } from './fake.ts';

function countingFetch(body: unknown) {
  const urls: string[] = [];
  const f = (async (url: string | URL | Request) => {
    urls.push(String(url));
    return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } });
  }) as typeof fetch;
  return { f, urls };
}
function budget(left: Partial<Record<MapsSku, number>>) {
  const asked: MapsSku[] = [];
  const take = async (sku: MapsSku) => { asked.push(sku); const n = left[sku] ?? 0; left[sku] = n - 1; return n > 0; };
  return { take, asked };
}
const A = { lat: 43.6453, lng: -79.3806 }, B = { lat: 43.6777, lng: -79.6248 };

test('within budget: each Google call takes one from its own SKU', async () => {
  const { f, urls } = countingFetch({ suggestions: [{ placePrediction: { placeId: 'ChIJ1', text: { text: '65 Front St W' } } }],
    id: 'ChIJ1', formattedAddress: '65 Front St W', location: { latitude: 43.6, longitude: -79.3 }, routes: [{ distanceMeters: 25300 }] });
  const b = budget({ autocomplete: 1, place_details: 1, routes: 1 });
  const m = budgetedMaps(googleMaps('k', { fetch: f }), fakeMaps(), b.take);
  assert.equal(m.name, 'google');
  assert.deepEqual(await m.autocomplete('65 front', 's1'), [{ id: 'ChIJ1', label: '65 Front St W' }]);
  assert.equal((await m.place('ChIJ1', 's1'))?.id, 'ChIJ1');
  assert.equal(await m.distanceKm(A, B), 25.3);
  assert.deepEqual(b.asked, ['autocomplete', 'place_details', 'routes']);
  assert.equal(urls.length, 3);
});

test('budget used up: Google is not called; no suggestions, no place, the straight-line distance', async () => {
  const { f, urls } = countingFetch({});
  const b = budget({ autocomplete: 1 });
  const m = budgetedMaps(googleMaps('k', { fetch: f }), fakeMaps(), b.take);
  await m.autocomplete('union station', 's');
  assert.equal(urls.length, 1, 'the last call of the budget goes to Google');
  assert.deepEqual(await m.autocomplete('union station', 's'), [], 'over the cap: the person types the address');
  assert.equal(await m.place('ChIJ1', 's'), null, 'over the cap: distance to be confirmed');
  const est = await m.distanceKm(A, B);
  assert.equal(est, await fakeMaps().distanceKm(A, B), 'over the cap: the fake adapter\'s estimate');
  assert.ok(est !== null && est > 15 && est < 30);
  assert.equal(urls.length, 1, 'nothing else reached Google');
});

test('budget unreadable (database down): treated as over budget, never an error', async () => {
  const { f, urls } = countingFetch({});
  const m = budgetedMaps(googleMaps('k', { fetch: f }), fakeMaps(), async () => { throw new Error('connect ECONNREFUSED'); });
  assert.deepEqual(await m.autocomplete('union station', 's'), []);
  assert.equal(await m.place('ChIJ1', 's'), null);
  assert.equal(await m.distanceKm(A, B), await fakeMaps().distanceKm(A, B));
  assert.equal(urls.length, 0);
});

test('nothing is taken from the budget for input Google would not be asked about', async () => {
  const { f, urls } = countingFetch({});
  const b = budget({ autocomplete: 5, place_details: 5 });
  const m = budgetedMaps(googleMaps('k', { fetch: f }), fakeMaps(), b.take);
  assert.deepEqual(await m.autocomplete('  ab ', 's'), [], 'under 3 characters');
  assert.equal(await m.place('x', 's'), null, 'not a place id');
  assert.equal(await m.place('bad id!', 's'), null);
  assert.deepEqual(b.asked, []);
  assert.equal(urls.length, 0);
});
