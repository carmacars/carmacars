import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createSign } from 'node:crypto';
import { clearCertCache, isSnsCertUrl, isSnsUrl, sesEvents, stringToSign, verifySns, type SnsMessage } from './ses-sns.ts';

// A throwaway RSA key and a certificate for sns.amazonaws.com, made with openssl for this run only (nothing committed).
function makeCert(cn: string, days: number): { key: string; cert: string } {
  const d = mkdtempSync(join(tmpdir(), 'sns-test-'));
  try {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(d, 'k.pem'), '-out', join(d, 'c.pem'),
      '-days', String(days), '-subj', `/CN=${cn}`], { stdio: 'ignore' });
    return { key: readFileSync(join(d, 'k.pem'), 'utf8'), cert: readFileSync(join(d, 'c.pem'), 'utf8') };
  } finally { rmSync(d, { recursive: true, force: true }); }
}
const good = makeCert('sns.amazonaws.com', 30);
const other = makeCert('sns.amazonaws.com', 30);
const foreign = makeCert('example.com', 30);

const URL_OK = 'https://sns.ca-central-1.amazonaws.com/SimpleNotificationService-0123456789abcdef0123456789abcdef.pem';
function signed(over: Partial<SnsMessage> = {}, version: '1' | '2' = '2', key = good.key): string {
  const m: SnsMessage = { Type: 'Notification', MessageId: 'm-1', TopicArn: 'arn:aws:sns:ca-central-1:123456789012:ses-events', Message: '{"eventType":"Bounce"}',
    Timestamp: '2026-11-12T12:00:00.000Z', SignatureVersion: version, Signature: '', SigningCertURL: URL_OK, ...over };
  const sts = stringToSign(m)!;
  m.Signature = createSign(version === '1' ? 'RSA-SHA1' : 'RSA-SHA256').update(sts).sign(key, 'base64');
  return JSON.stringify(m);
}
const fetchGood = async () => good.cert;
const fetchOther = async () => other.cert;
const fetchForeign = async () => foreign.cert;

test('sns: a signature version 2 (SHA-256) message verifies', async () => {
  const r = await verifySns(signed(), { fetchCert: fetchGood });
  assert.equal(r.ok, true);
});

test('sns: a signature version 1 (SHA-1) message verifies, with a Subject', async () => {
  const r = await verifySns(signed({ Subject: 'Amazon SES Email Event Notification' }, '1'), { fetchCert: fetchGood });
  assert.equal(r.ok, true);
});

test('sns: a subscription confirmation verifies (its own signed fields)', async () => {
  const r = await verifySns(signed({ Type: 'SubscriptionConfirmation', Token: 'tok', SubscribeURL: 'https://sns.ca-central-1.amazonaws.com/?Action=ConfirmSubscription&Token=tok' }), { fetchCert: fetchGood });
  assert.equal(r.ok, true);
});

test('sns: a changed message, a signature from another key, a wrong version and a missing field are refused', async () => {
  const tampered = JSON.parse(signed()) as SnsMessage; tampered.Message = '{"eventType":"Complaint"}';
  assert.equal((await verifySns(JSON.stringify(tampered), { fetchCert: fetchGood })).ok, false);
  assert.equal((await verifySns(signed({}, '2', other.key), { fetchCert: fetchGood })).ok, false);
  clearCertCache();
  assert.equal((await verifySns(signed({}, '2'), { fetchCert: fetchOther })).ok, false);
  clearCertCache();
  const v1as2 = JSON.parse(signed({}, '1')) as SnsMessage; v1as2.SignatureVersion = '2';
  assert.equal((await verifySns(JSON.stringify(v1as2), { fetchCert: fetchGood })).ok, false);
  const nover = JSON.parse(signed()) as SnsMessage; nover.SignatureVersion = '3';
  assert.equal((await verifySns(JSON.stringify(nover), { fetchCert: fetchGood })).ok, false);
  const nomsg = JSON.parse(signed()) as Record<string, unknown>; delete nomsg.MessageId;
  assert.equal((await verifySns(JSON.stringify(nomsg), { fetchCert: fetchGood })).ok, false);
  assert.equal((await verifySns('not json', { fetchCert: fetchGood })).ok, false);
});

test('sns: the certificate must come from sns.<region>.amazonaws.com over https and belong to SNS', async () => {
  let fetched = 0;
  const count = async () => { fetched++; return good.cert; };
  for (const bad of ['http://sns.ca-central-1.amazonaws.com/x.pem', 'https://evil.example.com/x.pem', 'https://sns.ca-central-1.amazonaws.com.evil.com/x.pem',
    'https://sns.ca-central-1.amazonaws.com@evil.com/x.pem', 'https://sns.ca-central-1.amazonaws.com:8443/x.pem', 'https://amazonaws.com/x.pem', 'https://sns.ca-central-1.amazonaws.com/x.txt']) {
    assert.equal((await verifySns(signed({ SigningCertURL: bad }), { fetchCert: count })).ok, false, bad);
  }
  assert.equal(fetched, 0, 'no certificate is fetched from a refused URL');
  const r = await verifySns(signed({ SigningCertURL: URL_OK.replace('0123', '4567') }, '2', foreign.key), { fetchCert: fetchForeign });
  assert.equal(r.ok, false);
  assert.match(r.ok ? '' : r.reason, /not Amazon SNS/);
});

test('sns: an expired or not yet valid certificate is refused', async () => {
  const url = 'https://sns.us-east-1.amazonaws.com/SimpleNotificationService-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pem';
  const late = await verifySns(signed({ SigningCertURL: url }), { fetchCert: fetchGood, now: Date.now() + 90 * 86_400_000 });
  assert.equal(late.ok, false);
  const early = await verifySns(signed({ SigningCertURL: url.replace('aaaa', 'bbbb') }), { fetchCert: fetchGood, now: Date.now() - 90 * 86_400_000 });
  assert.equal(early.ok, false);
});

test('sns: a topic pin refuses another topic', async () => {
  assert.equal((await verifySns(signed(), { fetchCert: fetchGood, topicArn: 'arn:aws:sns:ca-central-1:123456789012:ses-events' })).ok, true);
  assert.equal((await verifySns(signed(), { fetchCert: fetchGood, topicArn: 'arn:aws:sns:ca-central-1:999999999999:other' })).ok, false);
});

test('sns: URL checks', () => {
  assert.equal(isSnsUrl('https://sns.ca-central-1.amazonaws.com/?Action=ConfirmSubscription&Token=t'), true);
  assert.equal(isSnsUrl('https://sns.ca-central-1.amazonaws.com.evil.com/'), false);
  assert.equal(isSnsUrl(42), false);
  assert.equal(isSnsCertUrl('https://sns.ca-central-1.amazonaws.com/a.pem'), true);
  assert.equal(isSnsCertUrl('https://sns.ca-central-1.amazonaws.com/a'), false);
});

const bounce = (type: string, extra = '') => JSON.stringify({ eventType: 'Bounce', mail: { messageId: 'abc' },
  bounce: { bounceType: type, bounceSubType: 'General', bouncedRecipients: [{ emailAddress: 'A@Example.com', diagnosticCode: 'smtp; 550 no such user' }, { emailAddress: 'b@example.com' }] }, ...(extra ? JSON.parse(extra) : {}) });

test('ses events: a permanent bounce suppresses each address (lowercased); transient and undetermined do not', () => {
  const e = sesEvents(bounce('Permanent'));
  assert.deepEqual(e.map((x) => [x.kind, x.email, x.messageId]), [['bounce', 'a@example.com', 'abc'], ['bounce', 'b@example.com', 'abc']]);
  assert.match(e[0]!.detail, /^Permanent\/General: smtp; 550/);
  assert.deepEqual(sesEvents(bounce('Transient')), []);
  assert.deepEqual(sesEvents(bounce('Undetermined')), []);
});

test('ses events: complaints, the older notificationType form, and anything else', () => {
  const c = sesEvents(JSON.stringify({ eventType: 'Complaint', mail: { messageId: 'xyz' }, complaint: { complaintFeedbackType: 'abuse', complainedRecipients: [{ emailAddress: 'c@example.com' }] } }));
  assert.deepEqual(c.map((x) => [x.kind, x.email, x.messageId, x.detail]), [['complaint', 'c@example.com', 'xyz', 'Complaint: abuse']]);
  const old = sesEvents(JSON.stringify({ notificationType: 'Bounce', mail: { messageId: 'q' }, bounce: { bounceType: 'Permanent', bouncedRecipients: [{ emailAddress: 'd@example.com' }] } }));
  assert.equal(old.length, 1);
  assert.deepEqual(sesEvents(JSON.stringify({ eventType: 'Delivery', mail: { messageId: 'q' } })), []);
  assert.deepEqual(sesEvents('nope'), []);
  assert.deepEqual(sesEvents(JSON.stringify({ eventType: 'Bounce', bounce: { bounceType: 'Permanent', bouncedRecipients: [{ emailAddress: 'not an address' }] } })), []);
});
