import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SignJWT, decodeJwt } from 'jose';
import { mintToken, verifyWebhook, videoGrant, webhookEvent, TOKEN_SECONDS } from './token.ts';

const ID = 'u-11111111-2222-3333-4444-555555555555';
test('5010: a short token for one person and one room', async () => {
  const now = Date.parse('2026-11-25T18:00:00Z');
  const t = await mintToken('APIkey1', 'secret-of-32-characters-at-least!!', { room: 'townhall-20261125-1300', identity: ID, name: 'Sam', role: 'member' }, now);
  const c = decodeJwt(t) as Record<string, unknown> & { video: Record<string, unknown> };
  assert.equal(c.iss, 'APIkey1');
  assert.equal(c.sub, ID);
  assert.equal(c.exp, now / 1000 + TOKEN_SECONDS);
  assert.equal(c.video.room, 'townhall-20261125-1300');
  assert.equal(c.video.roomJoin, true);
  assert.equal(c.video.roomAdmin, false);
  assert.equal(JSON.parse(String(c.metadata)).role, 'member');
  await assert.rejects(mintToken('k', 's', { room: 'Bad Room!', identity: ID, name: 'x', role: 'member' }));
  await assert.rejects(mintToken('k', 's', { room: 'iv-room-1', identity: 'admin', name: 'x', role: 'member' }));
});

test('5010: the presenter and the interviewer moderate; a guest does not', () => {
  assert.equal(videoGrant({ room: 'r', identity: ID, name: 'A', role: 'presenter' }).roomAdmin, true);
  assert.equal(videoGrant({ room: 'r', identity: ID, name: 'A', role: 'host' }).roomAdmin, true);
  assert.equal(videoGrant({ room: 'r', identity: ID, name: 'A', role: 'guest' }).roomAdmin, false);
});

test('5010: the webhook is checked (key, secret, the body hash) and read', async () => {
  const body = JSON.stringify({ event: 'participant_joined', room: { name: 'townhall-20261125-1300' }, participant: { identity: ID }, createdAt: 1764093600 });
  const h = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body)))));
  const sign = (sha: string, secret = 'sec') => new SignJWT({ sha256: sha }).setProtectedHeader({ alg: 'HS256' }).setIssuer('key').setIssuedAt().setExpirationTime('5m').sign(new TextEncoder().encode(secret));
  assert.equal(await verifyWebhook('key', 'sec', body, `Bearer ${await sign(h)}`), true);
  assert.equal(await verifyWebhook('key', 'sec', body, await sign(h)), true);
  assert.equal(await verifyWebhook('key', 'sec', body + ' ', await sign(h)), false);
  assert.equal(await verifyWebhook('key', 'sec', body, await sign(h, 'other')), false);
  assert.equal(await verifyWebhook('other', 'sec', body, await sign(h)), false);
  assert.equal(await verifyWebhook('key', 'sec', body, null), false);
  assert.deepEqual(webhookEvent(JSON.parse(body)), { room: 'townhall-20261125-1300', identity: ID, event: 'joined', at: '2025-11-25T18:00:00.000Z' });
  assert.equal(webhookEvent({ event: 'room_started', room: { name: 'x' } }), null);
  assert.equal(webhookEvent({ event: 'participant_left', room: { name: 'x' }, participant: { identity: 'EG_egress' } }), null);
});
