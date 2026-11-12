import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifySesError, emailProviderOrder, sesMaySend, mimeMessage, sesConfig, sesSend, signingKeyHex, sigV4 } from './email-ses.ts';

// AWS's published examples (example keys only, from the AWS documentation)
const SECRET = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';

test('ses sigv4: the signing key of the AWS docs example (iam, us-east-1, 20120215)', async () => {
  assert.equal(await signingKeyHex(SECRET, '20120215', 'us-east-1', 'iam'), 'f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d');
});

test('ses sigv4: AWS test suite get-vanilla', async () => {
  const h = await sigV4({ method: 'GET', url: 'https://example.amazonaws.com/', region: 'us-east-1', service: 'service', accessKeyId: 'AKIDEXAMPLE',
    secretAccessKey: SECRET, amzDate: '20150830T123600Z' });
  assert.equal(h.authorization ?? '', 'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31');
  assert.equal(h['x-amz-date'], '20150830T123600Z');
});

test('ses sigv4: AWS test suite post-vanilla', async () => {
  const h = await sigV4({ method: 'POST', url: 'https://example.amazonaws.com/', region: 'us-east-1', service: 'service', accessKeyId: 'AKIDEXAMPLE',
    secretAccessKey: SECRET, amzDate: '20150830T123600Z' });
  assert.match(h.authorization ?? '', /Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b$/);
});

test('ses sigv4: AWS test suite get-vanilla-query-order-key-case', async () => {
  const h = await sigV4({ method: 'GET', url: 'https://example.amazonaws.com/?Param2=value2&Param1=value1', region: 'us-east-1', service: 'service',
    accessKeyId: 'AKIDEXAMPLE', secretAccessKey: SECRET, amzDate: '20150830T123600Z' });
  assert.match(h.authorization ?? '', /Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500$/);
});

test('ses config: no keys, no SES; the region defaults to ca-central-1', () => {
  assert.equal(sesConfig(() => undefined), null);
  assert.equal(sesConfig((k) => (k === 'AWS_SES_ACCESS_KEY_ID' ? 'AKIDEXAMPLE' : undefined)), null);
  const env: Record<string, string> = { AWS_SES_ACCESS_KEY_ID: 'AKIDEXAMPLE', AWS_SES_SECRET_ACCESS_KEY: SECRET };
  assert.deepEqual(sesConfig((k) => env[k]), { accessKeyId: 'AKIDEXAMPLE', secretAccessKey: SECRET, region: 'ca-central-1', configurationSet: undefined });
  env.AWS_SES_CONFIGURATION_SET = 'carmacars';
  assert.equal(sesConfig((k) => env[k])?.configurationSet, 'carmacars');
});

test('ses mime: HTML and text, Reply-To, the one-click unsubscribe headers, an encoded subject, attachments', () => {
  const m = mimeMessage({ from: 'CarmaCars <hello@example.test>', to: 'renter@example.test', reply_to: 'help@example.test', subject: 'Votre voiture est prête',
    html: '<p>Hello é</p>', text: 'Hello é', headers: { 'List-Unsubscribe': '<https://example.test/api/unsubscribe?token=t>', 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click' },
    attachments: [{ filename: 'statement.pdf', content: 'JVBERi0=', content_type: 'application/pdf' }] }, { boundary: 'B', date: new Date('2026-11-12T12:00:00Z') });
  assert.match(m, /^From: CarmaCars <hello@example\.test>\r\nTo: renter@example\.test\r\nReply-To: help@example\.test\r\n/);
  assert.match(m, /\r\nSubject: =\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=\r\n/);
  assert.match(m, /\r\nList-Unsubscribe: <https:\/\/example\.test\/api\/unsubscribe\?token=t>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n/);
  assert.match(m, /Content-Type: multipart\/mixed; boundary="Bm"/);
  assert.match(m, /Content-Type: multipart\/alternative; boundary="Ba"/);
  assert.match(m, /Content-Type: text\/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\nSGVsbG8gw6k=\r\n/);
  assert.match(m, /Content-Disposition: attachment; filename="statement\.pdf"/);
  assert.ok(m.endsWith('--Bm--\r\n'));
  // a line break in a header value cannot add a header
  assert.doesNotMatch(mimeMessage({ from: 'a@example.test', to: 'b@example.test', subject: 'x\r\nBcc: c@example.test', html: '', text: '' }), /\r\nBcc:/);
});

test('ses errors: rate → wait, MessageRejected → this email to the next provider, the rest → the account rests', () => {
  assert.equal(classifySesError(429, 'TooManyRequestsException', ''), 'throttle');
  assert.equal(classifySesError(400, 'MessageRejected', 'Email address is not verified. The following identities failed the check in region CA-CENTRAL-1: renter@example.test'), 'email');
  assert.equal(classifySesError(403, 'InvalidSignatureException', ''), 'account');
  assert.equal(classifySesError(400, 'SendingPausedException', ''), 'account');
  assert.equal(classifySesError(400, 'LimitExceededException', 'Daily message quota exceeded'), 'account');
  assert.equal(classifySesError(500, 'InternalFailure', ''), 'account');
});

test('ses send: SES v2 SendEmail, raw content, signed; the id or the classified error', async () => {
  const c = { accessKeyId: 'AKIDEXAMPLE', secretAccessKey: SECRET, region: 'ca-central-1', configurationSet: 'cc' };
  const mail = { from: 'CarmaCars <hello@example.test>', to: 'renter@example.test', subject: 'Hi', html: '<p>Hi</p>', text: 'Hi' };
  let seen: { url: string; init: RequestInit } | null = null;
  const ok = (async (url: string, init: RequestInit) => { seen = { url, init }; return new Response(JSON.stringify({ MessageId: 'm-1' }), { status: 200 }); }) as unknown as typeof fetch;
  assert.deepEqual(await sesSend(c, mail, ok), { id: 'm-1' });
  const s = seen as unknown as { url: string; init: RequestInit };
  assert.equal(s.url, 'https://email.ca-central-1.amazonaws.com/v2/email/outbound-emails');
  const body = JSON.parse(String(s.init.body));
  assert.equal(body.ConfigurationSetName, 'cc');
  assert.deepEqual(body.Destination, { ToAddresses: ['renter@example.test'] });
  assert.match(Buffer.from(body.Content.Raw.Data, 'base64').toString('utf8'), /^From: CarmaCars <hello@example\.test>\r\n/);
  assert.match((s.init.headers as Record<string, string>).authorization ?? '', /^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/\d{8}\/ca-central-1\/ses\/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=[0-9a-f]{64}$/);
  const rejected = (async () => new Response(JSON.stringify({ message: 'Email address is not verified.' }), { status: 400, headers: { 'x-amzn-ErrorType': 'MessageRejected:http://internal.amazon.com/' } })) as unknown as typeof fetch;
  assert.deepEqual(await sesSend(c, mail, rejected), { error: 'SES 400 MessageRejected: Email address is not verified.', kind: 'email' });
  const down = (async () => { throw new Error('connection reset'); }) as unknown as typeof fetch;
  assert.equal(((await sesSend(c, mail, down)) as { kind: string }).kind, 'account');
});

test('ses order: SES first when configured, on, with budget and not resting; then Cloudflare, then Resend', () => {
  const base = { sesConfigured: true, sesEnabled: true, sesLeft: 200, sesResting: false, cfOn: true, cfLeft: 100, resendLeft: 100 };
  assert.deepEqual(emailProviderOrder(base), ['ses', 'cf', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...base, sesConfigured: false }), ['cf', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...base, sesEnabled: false }), ['cf', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...base, sesLeft: 0 }), ['cf', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...base, sesResting: true }), ['cf', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...base, cfOn: false }), ['ses', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...base, sesLeft: 0, cfLeft: 0, resendLeft: 0 }), []);
});

test('ses order: marketing never goes through SES unless email_ses_marketing is on', () => {
  const base = { sesConfigured: true, sesEnabled: true, sesLeft: 200, cfOn: true, cfLeft: 100, resendLeft: 100 };
  assert.deepEqual(emailProviderOrder({ ...base, category: 'marketing' }), ['resend']);
  assert.deepEqual(emailProviderOrder({ ...base, category: 'marketing', sesMarketing: true }), ['ses', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...base, category: 'transactional' }), ['ses', 'cf', 'resend']);
  assert.equal(sesMaySend('marketing', false), false);
  assert.equal(sesMaySend('transactional', false), true);
  assert.equal(sesMaySend('staff', false), true);
});

test('email route (2600): booking and system email SES then Resend; marketing Resend only; Cloudflare off by default', () => {
  // email_cloudflare_enabled off: the database reports no Cloudflare budget (cfOn false, cfLeft 0)
  const off = { sesConfigured: true, sesEnabled: true, sesLeft: 200, sesResting: false, cfOn: false, cfLeft: 0, resendLeft: 100 };
  for (const category of ['transactional', 'staff', 'digest', undefined]) assert.deepEqual(emailProviderOrder({ ...off, category }), ['ses', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...off, category: 'marketing' }), ['resend']);
  // SES not set up, resting, used up or off: Resend's free plan sends the booking email
  assert.deepEqual(emailProviderOrder({ ...off, category: 'transactional', sesConfigured: false }), ['resend']);
  assert.deepEqual(emailProviderOrder({ ...off, category: 'transactional', sesResting: true }), ['resend']);
  assert.deepEqual(emailProviderOrder({ ...off, category: 'transactional', sesLeft: 0 }), ['resend']);
  // Resend's free day used: nothing may send (held, never a paid plan)
  assert.deepEqual(emailProviderOrder({ ...off, category: 'marketing', resendLeft: 0 }), []);
  // Cloudflare switched on again: booking email may use it after SES, marketing never
  const on = { ...off, cfOn: true, cfLeft: 50 };
  assert.deepEqual(emailProviderOrder({ ...on, category: 'transactional' }), ['ses', 'cf', 'resend']);
  assert.deepEqual(emailProviderOrder({ ...on, category: 'marketing' }), ['resend']);
});
