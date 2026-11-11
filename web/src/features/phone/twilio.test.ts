import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { bridgeTwiml, callToken, dialOutcome, hangupTwiml, recordingKey, recordingReady, recordingUrls, startCallForm, twilioReady, twilioSignature, verifyCallToken, verifyTwilioSignature } from './twilio.ts';

// Twilio's documented scheme, computed here independently with Node's own HMAC: the full URL, then each POST parameter
// sorted by name, each name followed by its value; HMAC-SHA1 with the Auth Token; base64.
const TOKEN = '12345';
const URL_ = 'https://mycompany.example.test/myapp.php?foo=1&bar=2';
const PARAMS = { CallSid: 'CA1234567890ABCDE', Caller: '+12349013030', Digits: '1234', From: '+12349013030', To: '+18005551212' };
const nodeSig = (token: string, url: string, p: Record<string, string>) =>
  createHmac('sha1', token).update(url + Object.keys(p).sort().map((k) => k + p[k]).join('')).digest('base64');

test('signature: the same as the documented scheme', async () => {
  assert.equal(await twilioSignature(TOKEN, URL_, PARAMS), nodeSig(TOKEN, URL_, PARAMS));
});

test('signature: the parameters are sorted by name, whatever order they came in', async () => {
  const shuffled = { To: PARAMS.To, Digits: PARAMS.Digits, CallSid: PARAMS.CallSid, From: PARAMS.From, Caller: PARAMS.Caller };
  assert.equal(await twilioSignature(TOKEN, URL_, shuffled), await twilioSignature(TOKEN, URL_, PARAMS));
});

test('signature check: a good one passes; a changed parameter, URL or token fails; no token or no header fails closed', async () => {
  const good = nodeSig(TOKEN, URL_, PARAMS);
  assert.equal(await verifyTwilioSignature(TOKEN, URL_, PARAMS, good), true);
  assert.equal(await verifyTwilioSignature(TOKEN, URL_, { ...PARAMS, Digits: '1235' }, good), false);
  assert.equal(await verifyTwilioSignature(TOKEN, URL_ + '&x=1', PARAMS, good), false);
  assert.equal(await verifyTwilioSignature('54321', URL_, PARAMS, good), false);
  assert.equal(await verifyTwilioSignature(null, URL_, PARAMS, good), false);
  assert.equal(await verifyTwilioSignature(TOKEN, URL_, PARAMS, null), false);
});

test('our call token: made from the call id and the secret only', async () => {
  const t = await callToken('a-server-secret', '1b2c3d4e-0000-4000-8000-000000000001');
  assert.match(t, /^[0-9a-f]{40}$/);
  assert.equal(await verifyCallToken('a-server-secret', '1b2c3d4e-0000-4000-8000-000000000001', t), true);
  assert.equal(await verifyCallToken('a-server-secret', '1b2c3d4e-0000-4000-8000-000000000002', t), false);
  assert.equal(await verifyCallToken('another-secret', '1b2c3d4e-0000-4000-8000-000000000001', t), false);
  assert.equal(await verifyCallToken(undefined, '1b2c3d4e-0000-4000-8000-000000000001', t), false);
});

test('TwiML: a short message, then the customer with the CarmaCars number as caller ID', () => {
  const x = bridgeTwiml({ to: '+16475550199', callerId: '+16475550100', actionUrl: 'https://carmacars.example.test/api/webhooks/twilio/dial?id=1&t=abc', say: 'Connecting you to R & D.' });
  assert.equal(x, '<?xml version="1.0" encoding="UTF-8"?><Response><Say voice="alice" language="en-CA">Connecting you to R &amp; D.</Say>'
    + '<Dial callerId="+16475550100" timeout="30" answerOnBridge="true" action="https://carmacars.example.test/api/webhooks/twilio/dial?id=1&amp;t=abc" method="POST">'
    + '<Number>+16475550199</Number></Dial></Response>');
});

test('TwiML: refuses a number that is not E.164 (nothing typed reaches the dial)', () => {
  assert.throws(() => bridgeTwiml({ to: '647 555 0199', callerId: '+16475550100', actionUrl: 'https://x.example.test/' }), /E\.164/);
  assert.throws(() => bridgeTwiml({ to: '+16475550199</Number><Number>+19005550000', callerId: '+16475550100', actionUrl: 'https://x.example.test/' }), /E\.164/);
  assert.throws(() => bridgeTwiml({ to: '+16475550199', callerId: 'CarmaCars', actionUrl: 'https://x.example.test/' }), /caller ID/);
});

test('TwiML: hang up, with or without words', () => {
  assert.equal(hangupTwiml(), '<?xml version="1.0" encoding="UTF-8"?><Response><Hangup/></Response>');
  assert.match(hangupTwiml('Goodbye <now>'), /<Say[^>]*>Goodbye &lt;now&gt;<\/Say><Hangup\/>/);
});

test('the REST call: rings the staff cell from our number, with the status events', () => {
  const f = startCallForm({ staffNumber: '+16475550161', callerId: '+16475550100', voiceUrl: 'https://x.example.test/v', statusUrl: 'https://x.example.test/s' });
  assert.equal(f.get('To'), '+16475550161');
  assert.equal(f.get('From'), '+16475550100');
  assert.deepEqual(f.getAll('StatusCallbackEvent'), ['initiated', 'answered', 'completed']);
  assert.equal(f.get('Timeout'), '25');
});

test('ready: names the missing secrets, checks the account SID', () => {
  assert.deepEqual(twilioReady({}), { ready: false, why: 'Calling from the site is not set up yet (TWILIO_ACCOUNT_SID, TWILIO_API_KEY, TWILIO_API_SECRET not saved).' });
  assert.equal(twilioReady({ accountSid: 'xx', apiKey: 'SK1', apiSecret: 's' }).ready, false);
  assert.equal(twilioReady({ accountSid: 'AC' + '0'.repeat(32), apiKey: 'SK1', apiSecret: 's' }).ready, true);
});

test('outcome words', () => {
  assert.equal(dialOutcome('completed'), 'connected');
  assert.equal(dialOutcome('no-answer'), 'no answer');
  assert.equal(dialOutcome('failed'), 'did not connect');
});

// 1880: the recording of the customer leg and its callback
test('recording: the Dial records the customer leg and posts to the recording webhook', () => {
  const x = bridgeTwiml({ to: '+16475550199', callerId: '+16475550100', actionUrl: 'https://carmacars.example.test/api/webhooks/twilio/dial?id=1&t=abc',
    recordingUrl: 'https://carmacars.example.test/api/webhooks/twilio/recording?id=1&t=abc' });
  assert.match(x, / record="record-from-answer-dual" /);
  assert.match(x, /recordingStatusCallback="https:\/\/carmacars\.example\.test\/api\/webhooks\/twilio\/recording\?id=1&amp;t=abc"/);
  assert.match(x, /recordingStatusCallbackEvent="completed"/);
  assert.doesNotMatch(bridgeTwiml({ to: '+16475550199', callerId: '+16475550100', actionUrl: 'https://x.example.test/d' }), /record=/);
});
test('recording webhook: the signature covers the recording callback\'s parameters, and the per-call token is bound to the call', async () => {
  const url = 'https://carmacars.example.test/api/webhooks/twilio/recording?id=0b8f6a52-6c1e-4c3b-9d7e-2a1f3c4d5e6f&t=abc';
  const p = { AccountSid: 'AC' + '0'.repeat(32), CallSid: 'CA' + '1'.repeat(32), RecordingSid: 'RE' + 'a'.repeat(32), RecordingStatus: 'completed', RecordingDuration: '42', RecordingChannels: '2' };
  const sig = nodeSig(TOKEN, url, p);
  assert.equal(await verifyTwilioSignature(TOKEN, url, p, sig), true);
  assert.equal(await verifyTwilioSignature(TOKEN, url, { ...p, RecordingSid: 'RE' + 'b'.repeat(32) }, sig), false, 'another recording');
  assert.equal(await verifyTwilioSignature(TOKEN, url.replace('recording', 'dial'), p, sig), false, 'another webhook');
  assert.equal(await verifyTwilioSignature(null, url, p, sig), false, 'no token: closed');
  const id = '0b8f6a52-6c1e-4c3b-9d7e-2a1f3c4d5e6f';
  const t = await callToken('secret-1', id);
  assert.equal(await verifyCallToken('secret-1', id, t), true);
  assert.equal(await verifyCallToken('secret-1', id.replace('0b', '1b'), t), false, 'token of another call');
  assert.equal(await verifyCallToken('secret-2', id, t), false, 'another secret');
  assert.equal(await verifyCallToken('secret-1', id, null), false, 'no token');
});
test('recording: only a completed recording with a real SID is copied; its URLs and our key', () => {
  assert.deepEqual(recordingReady({ RecordingSid: 'RE' + 'a'.repeat(32), RecordingStatus: 'completed', RecordingDuration: '42' }), { sid: 'RE' + 'a'.repeat(32), seconds: 42 });
  assert.equal(recordingReady({ RecordingSid: 'RE' + 'a'.repeat(32), RecordingStatus: 'failed' }), null);
  assert.equal(recordingReady({ RecordingSid: '../../x', RecordingStatus: 'completed' }), null);
  const u = recordingUrls('AC' + '0'.repeat(32), 'RE' + 'a'.repeat(32));
  assert.equal(u.audio, `https://api.twilio.com/2010-04-01/Accounts/AC${'0'.repeat(32)}/Recordings/RE${'a'.repeat(32)}.mp3`);
  assert.ok(u.resource.endsWith('.json'));
  assert.equal(recordingKey('0B8F6A52-6C1E-4C3B-9D7E-2A1F3C4D5E6F'), 'calls/twilio/0b8f6a52-6c1e-4c3b-9d7e-2a1f3c4d5e6f.mp3');
  assert.throws(() => recordingKey('../x'));
});
