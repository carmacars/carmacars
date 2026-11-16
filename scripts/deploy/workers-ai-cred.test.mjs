// r48 part AI: scripts/deploy/workers-ai-cred.mjs against a stand-in of Cloudflare's API (run by deploy-vps's node-smoke job):
// the secret first, a narrow token made by the CI token, the CI token itself, and the exact permission named when none works.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { choose, probe, PERMISSION, TOKEN_NAME } from './workers-ai-cred.mjs';

/** tokens: token -> 'ok' | 'quota' | 'denied'; canMint: the CI token may make account tokens. */
function api({ tokens, canMint = false }) {
  const calls = [];
  const made = [];
  const f = async (url, init = {}) => {
    const auth = (init.headers?.authorization ?? '').replace('Bearer ', '');
    const u = new URL(url);
    calls.push(`${init.method ?? 'GET'} ${u.pathname}`);
    const res = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
    if (u.pathname.includes('/ai/run/')) {
      const s = tokens[auth];
      if (s === 'ok') return res(200, { success: true, result: { response: 'OK' } });
      if (s === 'quota') return res(429, { success: false, errors: [{ code: 4006, message: 'you have used up your daily free allocation of 10,000 neurons' }] });
      return res(403, { success: false, errors: [{ code: 10000, message: 'Authentication error' }] });
    }
    if (u.pathname.endsWith('/tokens/permission_groups')) return canMint ? res(200, { success: true, result: [{ id: 'g-ai', name: PERMISSION }, { id: 'g-dns', name: 'DNS Write' }] }) : res(403, { success: false, errors: [{ code: 9109, message: 'Unauthorized' }] });
    if (u.pathname.endsWith('/tokens') && init.method === 'POST') {
      const b = JSON.parse(init.body);
      assert.equal(b.name, TOKEN_NAME);
      assert.deepEqual(b.policies[0].permission_groups, [{ id: 'g-ai' }], 'the made token has Workers AI Read and nothing else');
      const value = `minted-${made.length + 1}`;
      made.push(value); tokens[value] = 'ok';
      return res(200, { success: true, result: { id: `id-${made.length}`, value } });
    }
    if (u.pathname.endsWith('/tokens')) return res(200, { success: true, result: [1, 2, 3].map((i) => ({ id: `id-${i}`, name: TOKEN_NAME, issued_on: `2026-11-1${i}T00:00:00Z` })) });
    if (init.method === 'DELETE') return res(200, { success: true });
    return res(404, { success: false });
  };
  return { f, calls, made };
}
const ENV = { CLOUDFLARE_ACCOUNT_ID: 'acc' };

test('the probe: ok, allowance used (the token works), no permission', async () => {
  const { f } = api({ tokens: { a: 'ok', b: 'quota', c: 'denied' } });
  assert.equal((await probe('acc', 'a', f)).probe, 'ok');
  assert.equal((await probe('acc', 'b', f)).probe, 'allowance_used');
  assert.equal((await probe('acc', 'c', f)).probe, 'no_permission');
  assert.equal((await probe('acc', 'x', async () => { throw new Error('offline'); })).probe, 'error');
});

test('the WORKERS_AI_API_TOKEN secret is used when it works; the CI token is not touched', async () => {
  const { f, calls } = api({ tokens: { s: 'ok', ci: 'ok' }, canMint: true });
  const r = await choose({ ...ENV, WORKERS_AI_API_TOKEN: 's', CLOUDFLARE_API_TOKEN: 'ci' }, f);
  assert.deepEqual([r.token, r.source, r.probe], ['s', 'secret', 'ok']);
  assert.equal(calls.length, 1);
});

test('no secret, the CI token may make tokens: the server gets a Workers AI Read token only; old ones beyond two removed', async () => {
  const { f, calls, made } = api({ tokens: { ci: 'ok' }, canMint: true });
  const r = await choose({ ...ENV, CLOUDFLARE_API_TOKEN: 'ci' }, f);
  assert.deepEqual([r.token, r.source, r.probe], ['minted-1', 'minted', 'ok']);
  assert.equal(made.length, 1);
  assert.deepEqual(calls.filter((c) => c.startsWith('DELETE')), ['DELETE /client/v4/accounts/acc/tokens/id-1']);
});

test('no secret, the CI token may not make tokens: the CI token itself, with a warning naming the narrower way', async () => {
  const { f } = api({ tokens: { ci: 'quota' } });
  const r = await choose({ ...ENV, CLOUDFLARE_API_TOKEN: 'ci' }, f);
  assert.deepEqual([r.token, r.source, r.probe], ['ci', 'ci', 'allowance_used']);
  assert.match(r.message, /Account API Tokens > Edit/);
});

test('no token may run Workers AI: none, and the exact permission to add', async () => {
  const { f } = api({ tokens: { ci: 'denied', s: 'denied' } });
  const r = await choose({ ...ENV, WORKERS_AI_API_TOKEN: 's', CLOUDFLARE_API_TOKEN: 'ci' }, f);
  assert.deepEqual([r.token, r.source, r.probe], ['', 'none', 'no_permission']);
  assert.match(r.message, /Account > Workers AI Read/);
  const none = await choose({ CLOUDFLARE_API_TOKEN: 'ci' }, f);
  assert.equal(none.source, 'none');
});
