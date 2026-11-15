// Unit tests for the Gemini route (gemini-route.ts): a call refused for its location goes again through the relay, and the
// rest of the Worker's calls go straight there; without a relay the refusal is answered as it came.
//   node --test --experimental-strip-types src/integrations/photos/gemini-route.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { geminiDirectRefused, geminiPost, isLocationRefusal, relayFrom, resetGeminiRoute } from './gemini-route.ts';
import { geminiCheckImages, geminiEditImage } from './gemini.ts';

const REFUSED = { error: { code: 400, message: 'User location is not supported for the API use.', status: 'FAILED_PRECONDITION' } };
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const relay = { url: 'https://api.example.test/gemini', key: 'service-key' };

test('a location refusal is told apart from other errors', () => {
  assert.equal(isLocationRefusal(400, REFUSED), true);
  assert.equal(isLocationRefusal(400, { error: { message: 'Invalid argument' } }), false);
  assert.equal(isLocationRefusal(429, REFUSED), false);
  assert.equal(isLocationRefusal(403, { error: { message: 'Gemini API is not available in your country' } }), true);
});

test('the relay: the database API plus /gemini with the service key; an override wins; nothing without a key', () => {
  assert.deepEqual(relayFrom('https://api.example.test/', 'k'), { url: 'https://api.example.test/gemini', key: 'k' });
  assert.deepEqual(relayFrom('https://api.example.test', 'k', 'https://relay.example.test/g/'), { url: 'https://relay.example.test/g', key: 'k' });
  assert.equal(relayFrom('https://api.example.test', null), null);
  assert.equal(relayFrom(null, 'k'), null);
  assert.equal(relayFrom('ftp://x', 'k'), null);
});

test('refused for its location: sent again through the relay with the service key, then straight to the relay', async () => {
  resetGeminiRoute();
  const calls: Array<{ url: string; apikey: string | null; goog: string | null }> = [];
  const f = (async (url: string, init: RequestInit) => {
    const h = init.headers as Record<string, string>;
    calls.push({ url, apikey: h.apikey ?? null, goog: h['x-goog-api-key'] ?? null });
    return url.startsWith('https://generativelanguage') ? json(400, REFUSED) : json(200, { ok: 1 });
  }) as unknown as typeof fetch;
  const a = await geminiPost({ apiKey: 'gk', relay, fetch: f }, '/v1beta/models/m:generateContent', {});
  assert.equal(a.via, 'relay');
  assert.equal(a.res.status, 200);
  assert.deepEqual(calls.map((c) => c.url), ['https://generativelanguage.googleapis.com/v1beta/models/m:generateContent', 'https://api.example.test/gemini/v1beta/models/m:generateContent']);
  assert.equal(calls[1]!.apikey, 'service-key');
  assert.equal(calls[1]!.goog, 'gk', 'Google still checks its own key');
  assert.equal(geminiDirectRefused(), true);
  await geminiPost({ apiKey: 'gk', relay, fetch: f }, '/v1beta/models/m:generateContent', {});
  assert.equal(calls.length, 3, 'the next call goes straight to the relay');
  assert.match(calls[2]!.url, /api\.example\.test/);
  resetGeminiRoute();
});

test('the image call: a location refusal with no relay is a "location" failure (a wait), never the photo\'s fault', async () => {
  resetGeminiRoute();
  const f = (async () => json(400, REFUSED)) as unknown as typeof fetch;
  const r = await geminiEditImage({ apiKey: 'gk', fetch: f }, { bytes: new Uint8Array([1, 2, 3]), contentType: 'image/jpeg' }, 'words');
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.reason, 'location');
  resetGeminiRoute();
  // through the relay it is made
  const img = btoa(String.fromCharCode(0xff, 0xd8, 0xff));
  const g = (async (url: string) => url.startsWith('https://generativelanguage') ? json(400, REFUSED)
    : json(200, { candidates: [{ content: { parts: [{ inlineData: { mimeType: 'image/jpeg', data: img } }] } }] })) as unknown as typeof fetch;
  const ok = await geminiEditImage({ apiKey: 'gk', fetch: g, relay }, { bytes: new Uint8Array([1]), contentType: 'image/jpeg' }, 'words');
  assert.equal(ok.ok, true);
  const check = await geminiCheckImages({ apiKey: 'gk', fetch: (async () => json(200, { candidates: [{ content: { parts: [{ text: '{"a": true}' }] } }] })) as unknown as typeof fetch, relay },
    [{ bytes: new Uint8Array([1]), contentType: 'image/jpeg' }], 'sys', 'words');
  assert.deepEqual(check?.data, { a: true });
  resetGeminiRoute();
});
