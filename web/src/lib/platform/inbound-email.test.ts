import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MAX_INBOUND_BYTES, inboundSecret, routeInbound, signInbound, verifyInbound, type InboundPost } from './inbound-email.ts';

const NOW = 1_800_000_000;

test('the forwarder secret is derived from the key and is not the key', async () => {
  const s = await inboundSecret('link-key');
  assert.match(s, /^[0-9a-f]{64}$/);
  assert.equal(s, await inboundSecret('link-key'));
  assert.notEqual(s, await inboundSecret('another-key'));
});

test('a signed message verifies; a changed message, envelope, time or secret does not', async () => {
  const s = await inboundSecret('link-key');
  const h = await signInbound(s, NOW, 'a@example.test', 'trips@in.carmacars.ca', 'Subject: x\r\n\r\nbody');
  assert.equal(await verifyInbound(s, h, 'a@example.test', 'trips@in.carmacars.ca', 'Subject: x\r\n\r\nbody', NOW + 10), true);
  assert.equal(await verifyInbound(s, h, 'a@example.test', 'trips@in.carmacars.ca', 'Subject: x\r\n\r\nother', NOW), false);
  assert.equal(await verifyInbound(s, h, 'b@example.test', 'trips@in.carmacars.ca', 'Subject: x\r\n\r\nbody', NOW), false);
  assert.equal(await verifyInbound(s, h, 'a@example.test', 'help@in.carmacars.ca', 'Subject: x\r\n\r\nbody', NOW), false);
  assert.equal(await verifyInbound(s, h, 'a@example.test', 'trips@in.carmacars.ca', 'Subject: x\r\n\r\nbody', NOW + 301), false);
  assert.equal(await verifyInbound('wrong', h, 'a@example.test', 'trips@in.carmacars.ca', 'Subject: x\r\n\r\nbody', NOW), false);
  for (const bad of [null, '', 't=1,v1=zz', `v1=${'a'.repeat(64)}`]) assert.equal(await verifyInbound(s, bad, 'a', 'b', 'c', NOW), false);
  assert.equal(await verifyInbound('', h, 'a@example.test', 'trips@in.carmacars.ca', 'Subject: x\r\n\r\nbody', NOW), false);
});

const poster = (answers: Record<string, { status: number; json: unknown }>) => {
  const calls: string[] = [];
  const post: InboundPost = async (path) => { calls.push(path); return answers[path] ?? { status: 500, json: null }; };
  return { calls, post };
};

test('trips@ goes straight to the Turo reader', async () => {
  const p = poster({ '/api/inbound/turo': { status: 200, json: { ok: true } } });
  assert.deepEqual(await routeInbound({ from: 'a@example.test', to: 'trips@in.carmacars.ca', raw: 'x' }, p.post), { status: 200, reply: null });
  assert.deepEqual(p.calls, ['/api/inbound/turo']);
});

test('an inbox with automatic answers is answered and never reaches the Turo reader', async () => {
  const p = poster({ '/api/inbound/ask': { status: 200, json: { handled: true, reply: { subject: 'Hours', text: 'We are open.', in_reply_to: 'id@x' } } } });
  assert.deepEqual(await routeInbound({ from: 'a@example.test', to: 'help@in.carmacars.ca', raw: 'x' }, p.post), { status: 200, reply: { subject: 'Hours', text: 'We are open.', in_reply_to: 'id@x' } });
  assert.deepEqual(p.calls, ['/api/inbound/ask']);
});

test('an address that is not such an inbox falls through to the Turo reader', async () => {
  const p = poster({ '/api/inbound/ask': { status: 404, json: { handled: false } }, '/api/inbound/turo': { status: 200, json: {} } });
  assert.equal((await routeInbound({ from: 'a@example.test', to: 'other@in.carmacars.ca', raw: 'x' }, p.post)).status, 200);
  assert.deepEqual(p.calls, ['/api/inbound/ask', '/api/inbound/turo']);
});

test('the app failing is a 502 (the sender tries again); too large is a 413', async () => {
  const down = poster({ '/api/inbound/turo': { status: 503, json: null } });
  assert.equal((await routeInbound({ from: 'a@example.test', to: 'trips@in.carmacars.ca', raw: 'x' }, down.post)).status, 502);
  const big = poster({});
  assert.equal((await routeInbound({ from: 'a@example.test', to: 'trips@in.carmacars.ca', raw: 'x'.repeat(MAX_INBOUND_BYTES + 1) }, big.post)).status, 413);
  assert.deepEqual(big.calls, []);
  const refused = poster({ '/api/inbound/turo': { status: 413, json: null } });
  assert.equal((await routeInbound({ from: 'a@example.test', to: 'trips@in.carmacars.ca', raw: 'x' }, refused.post)).status, 413);
});
