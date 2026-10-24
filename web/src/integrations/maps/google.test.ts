// Unit tests for the Google Maps adapter against a mocked fetch (no network, no key).
//   node --test --experimental-strip-types src/integrations/maps/google.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { googleMaps } from './google.ts';

type Call = { url: string; init: RequestInit };
function mock(responses: Array<{ status?: number; body: unknown } | Error>) {
  const calls: Call[] = [];
  const f = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    const r = responses.shift() ?? { status: 500, body: {} };
    if (r instanceof Error) throw r;
    return new Response(JSON.stringify(r.body), { status: r.status ?? 200, headers: { 'content-type': 'application/json' } });
  }) as typeof fetch;
  return { f, calls };
}
const h = (c: Call) => c.init.headers as Record<string, string>;

test('autocomplete: Places API (New) with the key in a header, a field mask, the session token, Canada only, biased to Toronto', async () => {
  const { f, calls } = mock([{ body: { suggestions: [
    { placePrediction: { placeId: 'ChIJ1', text: { text: '65 Front St W, Toronto, ON, Canada' } } },
    { queryPrediction: { text: { text: 'front street' } } },
    { placePrediction: { placeId: 'ChIJ2', text: { text: '100 Queen St W, Toronto, ON, Canada' } } }] } }]);
  const m = googleMaps('AIza-test', { fetch: f });
  const out = await m.autocomplete('  65 front  ', 'sess-1');
  assert.deepEqual(out, [{ id: 'ChIJ1', label: '65 Front St W, Toronto, ON, Canada' }, { id: 'ChIJ2', label: '100 Queen St W, Toronto, ON, Canada' }]);
  const c = calls[0]!;
  assert.equal(c.url, 'https://places.googleapis.com/v1/places:autocomplete');
  assert.equal(c.init.method, 'POST');
  assert.equal(h(c)['X-Goog-Api-Key'], 'AIza-test');
  assert.match(h(c)['X-Goog-FieldMask']!, /suggestions\.placePrediction\.placeId/);
  const body = JSON.parse(String(c.init.body));
  assert.equal(body.input, '65 front');
  assert.equal(body.sessionToken, 'sess-1');
  assert.deepEqual(body.includedRegionCodes, ['ca']);
  assert.equal(body.locationBias.circle.center.latitude, 43.6532);
  assert.ok(!c.url.includes('AIza'), 'the key is never in the URL');
});

test('autocomplete: a short query makes no call; an error or a network failure gives no suggestions', async () => {
  const { f, calls } = mock([{ status: 403, body: { error: { message: 'API key not valid' } } }, new Error('network down')]);
  const m = googleMaps('k', { fetch: f });
  assert.deepEqual(await m.autocomplete('a', 's'), []);
  assert.equal(calls.length, 0);
  assert.deepEqual(await m.autocomplete('union station', 's'), []);
  assert.deepEqual(await m.autocomplete('union station', 's'), []);
});

test('place details: the same session token closes the session; the address and coordinates come back', async () => {
  const { f, calls } = mock([{ body: { id: 'ChIJ1', formattedAddress: '65 Front St W, Toronto, ON M5J 1E6, Canada', location: { latitude: 43.6453, longitude: -79.3806 } } }]);
  const m = googleMaps('k', { fetch: f });
  const p = await m.place('ChIJ1', 'sess-1');
  assert.deepEqual(p, { id: 'ChIJ1', label: '65 Front St W, Toronto, ON M5J 1E6, Canada', lat: 43.6453, lng: -79.3806,
    parts: { street: '65 Front St W', unit: '', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' } });
  const c = calls[0]!;
  assert.match(c.url, /^https:\/\/places\.googleapis\.com\/v1\/places\/ChIJ1\?/);
  assert.match(c.url, /sessionToken=sess-1/);
  assert.equal(h(c)['X-Goog-FieldMask'], 'id,formattedAddress,location,addressComponents');
});

test('place details: a malformed id makes no call; a missing location is not a place', async () => {
  const { f, calls } = mock([{ body: { id: 'ChIJ9', formattedAddress: 'Somewhere' } }]);
  const m = googleMaps('k', { fetch: f });
  assert.equal(await m.place('../../etc', 's'), null);
  assert.equal(calls.length, 0);
  assert.equal(await m.place('ChIJ9', 's'), null);
});

test('distance: the Routes API by car from the company origin, in kilometres with one decimal', async () => {
  const { f, calls } = mock([{ body: { routes: [{ distanceMeters: 27349 }] } }]);
  const m = googleMaps('k', { fetch: f });
  const km = await m.distanceKm({ lat: 43.65, lng: -79.38 }, { lat: 43.68, lng: -79.61 });
  assert.equal(km, 27.3);
  const c = calls[0]!;
  assert.equal(c.url, 'https://routes.googleapis.com/directions/v2:computeRoutes');
  assert.equal(h(c)['X-Goog-FieldMask'], 'routes.distanceMeters');
  const body = JSON.parse(String(c.init.body));
  assert.equal(body.travelMode, 'DRIVE');
  assert.deepEqual(body.origin, { location: { latLng: { latitude: 43.65, longitude: -79.38 } } });
  assert.deepEqual(body.destination, { location: { latLng: { latitude: 43.68, longitude: -79.61 } } });
});

test('distance: no route, an error answer or a timeout is "not known" (null), never a made-up number', async () => {
  const { f } = mock([{ body: { routes: [] } }, { status: 500, body: {} }, new DOMException('timed out', 'TimeoutError')]);
  const m = googleMaps('k', { fetch: f });
  assert.equal(await m.distanceKm({ lat: 0, lng: 0 }, { lat: 1, lng: 1 }), null);
  assert.equal(await m.distanceKm({ lat: 0, lng: 0 }, { lat: 1, lng: 1 }), null);
  assert.equal(await m.distanceKm({ lat: 0, lng: 0 }, { lat: 1, lng: 1 }), null);
});
