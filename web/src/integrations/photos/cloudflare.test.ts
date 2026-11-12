import { test } from 'node:test';
import assert from 'node:assert/strict';
import { imageOptions, urlFormatFetch } from './cloudflare.ts';

test('transformations by address: the cut-out and a HEIC made a JPEG are plain options', () => {
  assert.equal(imageOptions({ segment: 'foreground', format: 'png', width: 2000, height: 1300, fit: 'scale-down' }), 'segment=foreground,format=png,width=2000,height=1300,fit=scale-down');
  assert.equal(imageOptions({ trim: { top: 1, right: 2, bottom: 3, left: 4 }, width: 10, quality: 85, brightness: 1.03 }), 'trim=1;2;3;4,width=10,quality=85,brightness=1.03');
});

test('transformations by address: draw (the composite) has no address form; nothing odd reaches the address', () => {
  assert.equal(imageOptions({ width: 10, draw: [{ url: 'https://x.test/a.png' }] }), null);
  assert.equal(imageOptions({ format: 'png/../x' }), null);
  assert.equal(imageOptions({}), null);
});

test('the request goes to /cdn-cgi/image on the zone; an option without an address form is answered 400 without a request', async () => {
  const seen: string[] = [];
  const f = urlFormatFetch('https://carmacars.ca/', (async (u: string) => { seen.push(u); return new Response('x', { headers: { 'content-type': 'image/jpeg' } }); }) as unknown as typeof fetch);
  const ok = await f('https://api.example.test/storage/a.heic?token=1', { cf: { image: { width: 2400, format: 'jpeg' } } });
  assert.equal(ok.status, 200);
  assert.deepEqual(seen, ['https://carmacars.ca/cdn-cgi/image/width=2400,format=jpeg/https://api.example.test/storage/a.heic?token=1']);
  assert.equal((await f('https://api.example.test/a.jpg', { cf: { image: { draw: [] } } })).status, 400);
  assert.equal(seen.length, 1);
});
