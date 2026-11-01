import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pushWaiting } from './cron-gate.ts';

// Phone and browser alerts (migration 0300): the five-minute tick runs the push job only with the VAPID keys and only
// when the database has an alert due. Placeholder strings stand in for the keys; nothing here is a real key.
const KEYS = { VAPID_PUBLIC_KEY: 'public-placeholder', VAPID_PRIVATE_KEY: 'private-placeholder' };
const DB = { DATA_BACKEND: 'supabase', NEXT_PUBLIC_SUPABASE_URL: 'https://db.example.test', SUPABASE_SERVICE_ROLE_KEY: 'service-placeholder' };
const answer = (body: string, status = 200) => (async () => new Response(body, { status })) as unknown as typeof fetch;
const never = (async () => assert.fail('no call without the keys')) as unknown as typeof fetch;

test('no keys: no call and no job', async () => {
  assert.equal(await pushWaiting({ ...DB }, never), false);
  assert.equal(await pushWaiting({ ...DB, VAPID_PUBLIC_KEY: 'x' }, never), false);
});

test('with the keys: the database decides; any doubt runs the job', async () => {
  let asked = '';
  const f = (async (url: string) => { asked = url; return new Response('false'); }) as unknown as typeof fetch;
  assert.equal(await pushWaiting({ ...DB, ...KEYS }, f), false);
  assert.equal(asked, 'https://db.example.test/rest/v1/rpc/server_push_waiting');
  assert.equal(await pushWaiting({ ...DB, ...KEYS }, answer('true')), true);
  assert.equal(await pushWaiting({ ...DB, ...KEYS }, answer('{}', 500)), true);
  assert.equal(await pushWaiting({ ...DB, ...KEYS }, (async () => { throw new Error('down'); }) as unknown as typeof fetch), true);
});
