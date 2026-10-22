import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { SMS_TEMPLATE, hookError, hookKey, parseSmsHook, signHook, smsCodeText, verifyHookSignature } from './sms-hook.ts';

// Supabase Auth's Send SMS hook (migration 0091): Standard Webhooks signatures and the payload.
const KEY = Buffer.from('a test hook secret of 32 bytes!!');
const SECRET = 'v1,whsec_' + KEY.toString('base64');
const hdr = (h: Record<string, string>) => (n: string) => h[n.toLowerCase()] ?? null;
const BODY = JSON.stringify({ user: { id: '7c9e6679-7425-40de-944b-e07fc1f90ae7', aud: 'authenticated', role: 'authenticated', email: '', phone: '16475551234', phone_confirmed_at: null }, sms: { otp: '123456' } });

test('a call Supabase signed passes: checked against an independent HMAC of "<id>.<timestamp>.<body>"', async () => {
  const now = 1_800_000_000;
  const independent = createHmac('sha256', KEY).update(`msg_2Q.${now}.${BODY}`).digest('base64');
  const h = { 'webhook-id': 'msg_2Q', 'webhook-timestamp': String(now), 'webhook-signature': `v1,${independent}` };
  assert.deepEqual(await verifyHookSignature(BODY, hdr(h), SECRET, now), { ok: true, id: 'msg_2Q' });
  assert.deepEqual(await signHook(BODY, SECRET, 'msg_2Q', now), h);
  // the secret as Supabase shows it, without "v1,", or only the base64 part
  assert.equal((await verifyHookSignature(BODY, hdr(h), 'whsec_' + KEY.toString('base64'), now)).ok, true);
  assert.equal((await verifyHookSignature(BODY, hdr(h), KEY.toString('base64'), now)).ok, true);
});

test('fails closed: a changed body, another secret, an old or future timestamp, no header, no secret', async () => {
  const now = 1_800_000_000;
  const h = await signHook(BODY, SECRET, 'msg_1', now);
  assert.equal((await verifyHookSignature(BODY.replace('123456', '654321'), hdr(h), SECRET, now)).reason, 'signature');
  assert.equal((await verifyHookSignature(BODY, hdr(h), 'v1,whsec_' + Buffer.from('another secret, also 32 bytes!!!').toString('base64'), now)).reason, 'signature');
  assert.equal((await verifyHookSignature(BODY, hdr(h), SECRET, now + 301)).reason, 'timestamp');
  assert.equal((await verifyHookSignature(BODY, hdr(h), SECRET, now - 301)).reason, 'timestamp');
  assert.equal((await verifyHookSignature(BODY, hdr({}), SECRET, now)).reason, 'no signature header');
  assert.equal((await verifyHookSignature(BODY, hdr(h), '', now)).reason, 'no secret');
  assert.equal((await verifyHookSignature(BODY, hdr(h), null, now)).reason, 'no secret');
  assert.equal(hookKey('v1,whsec_'), null);
});

test('a new secret beside the old one (rotation): either signs; several signatures in the header', async () => {
  const now = 1_800_000_000;
  const old = 'v1,whsec_' + Buffer.from('the previous hook secret 32 byte').toString('base64');
  const h = await signHook(BODY, old, 'msg_3', now);
  assert.equal((await verifyHookSignature(BODY, hdr(h), `${SECRET} ${old}`, now)).ok, true);
  assert.equal((await verifyHookSignature(BODY, hdr(h), [SECRET, old], now)).ok, true);
  const two = { ...h, 'webhook-signature': `v1,AAAA ${h['webhook-signature']}` };
  assert.equal((await verifyHookSignature(BODY, hdr(two), old, now)).ok, true);
});

test('payload: the code and the number (with +); a phone change texts the new number first', () => {
  assert.deepEqual(parseSmsHook(JSON.parse(BODY)), { userId: '7c9e6679-7425-40de-944b-e07fc1f90ae7', phones: ['+16475551234'], otp: '123456', type: null });
  const change = parseSmsHook({ user: { id: 'u', phone: '14165550101', new_phone: '16475550199' }, sms: { otp: '000123' } });
  assert.deepEqual(change?.phones, ['+16475550199', '+14165550101']);
  const signin = parseSmsHook({ user: { id: 'u', phone: '14165550101', new_phone: '16475550199' }, sms: { otp: '000123', sms_type: 'sms' } });
  assert.deepEqual(signin?.phones, ['+14165550101', '+16475550199']);
  assert.equal(parseSmsHook({ user: { phone: '16475551234' }, sms: {} }), null);
  assert.equal(parseSmsHook({ user: {}, sms: { otp: '123456' } }), null);
  assert.equal(parseSmsHook('nope'), null);
});

test('the text and the error shape Supabase reads', () => {
  assert.equal(smsCodeText('042917'), "CarmaCars code: 042917. It expires in 5 minutes. Don't share it.");
  assert.ok(SMS_TEMPLATE.includes('{{ .Code }}'));
  assert.ok(!/[–—]/.test(SMS_TEMPLATE));
  assert.deepEqual(hookError(502, 'Quo refused it'), { status: 502, body: { error: { http_code: 502, message: 'Quo refused it' } } });
});
