import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { bridgeTwiml, callToken, dialOutcome, hangupTwiml, startCallForm, twilioReady, twilioSignature, verifyCallToken, verifyTwilioSignature } from './twilio.ts';

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
