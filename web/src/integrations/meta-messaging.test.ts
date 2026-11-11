import { test } from 'node:test';
import assert from 'node:assert/strict';
import { incomingMessages, sendMetaReply, verifyMetaSignature } from './meta-messaging.ts';

const sign = async (raw: string, secret: string) => {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return 'sha256=' + Array.from(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw))), (x) => x.toString(16).padStart(2, '0')).join('');
};

test('the signature: right secret only', async () => {
  const raw = '{"object":"page"}';
  assert.equal(await verifyMetaSignature(raw, await sign(raw, 's3cret'), 's3cret'), true);
  assert.equal(await verifyMetaSignature(raw, await sign(raw, 'other'), 's3cret'), false);
  assert.equal(await verifyMetaSignature(raw, null, 's3cret'), false);
  assert.equal(await verifyMetaSignature(raw, await sign(raw, 's3cret'), ''), false, 'no secret: nothing is trusted');
});

test('Messenger, Instagram and WhatsApp texts; echoes and media without text left out', () => {
  assert.deepEqual(incomingMessages({ object: 'page', entry: [{ messaging: [
    { sender: { id: '111' }, recipient: { id: '999' }, message: { mid: 'm1', text: 'Do you deliver?' } },
    { sender: { id: '999' }, recipient: { id: '111' }, message: { mid: 'm2', text: 'Our answer', is_echo: true } },
    { sender: { id: '111' }, message: { mid: 'm3', attachments: [{}] } }] }] }),
  [{ channel: 'messenger', sender: '111', text: 'Do you deliver?', to: '999', id: 'm1' }]);
  assert.equal(incomingMessages({ object: 'instagram', entry: [{ messaging: [{ sender: { id: '5' }, message: { text: 'Deposit?' } }] }] })[0]!.channel, 'instagram');
  assert.deepEqual(incomingMessages({ object: 'whatsapp_business_account', entry: [{ changes: [{ value: { metadata: { phone_number_id: '42' },
    messages: [{ from: '14165550100', id: 'w1', type: 'text', text: { body: 'How old to rent?' } }, { from: '1', type: 'image' }] } }] }] }),
  [{ channel: 'whatsapp', sender: '14165550100', text: 'How old to rent?', to: '42', id: 'w1' }]);
  assert.deepEqual(incomingMessages('junk'), []);
});

test('answers go back through the Graph API with the right token; no token, nothing sent', async () => {
  const calls: Array<{ url: string; body: unknown; auth: string }> = [];
  const f = (async (url: string, init: RequestInit) => { calls.push({ url, body: JSON.parse(String(init.body)), auth: String((init.headers as Record<string, string>).authorization) }); return new Response('{}', { status: 200 }); }) as unknown as typeof fetch;
  assert.deepEqual(await sendMetaReply({ channel: 'messenger', to: '111', text: 'Yes', version: 'v21.0', pageToken: 'PT' }, f), { ok: true });
  assert.deepEqual(await sendMetaReply({ channel: 'whatsapp', to: '1416', text: 'Yes', version: 'v21.0', whatsappToken: 'WT', whatsappPhoneId: '42' }, f), { ok: true });
  assert.equal(calls[0]!.url, 'https://graph.facebook.com/v21.0/me/messages');
  assert.deepEqual(calls[0]!.body, { recipient: { id: '111' }, messaging_type: 'RESPONSE', message: { text: 'Yes' } });
  assert.equal(calls[1]!.url, 'https://graph.facebook.com/v21.0/42/messages');
  assert.equal(calls[1]!.auth, 'Bearer WT');
  assert.equal((await sendMetaReply({ channel: 'instagram', to: '5', text: 'x', version: 'v21.0', pageToken: null }, f)).ok, false);
  assert.equal(calls.length, 2);
});
