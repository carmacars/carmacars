import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fcmAccessToken, fcmAssertion, fcmMessage, fcmOutcomeOf, parseFcmAccount, resetFcmToken, sendFcm, type FcmAccount } from './fcm.ts';

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- the message is plain JSON read field by field
type Msg = { message: Record<string, any> };

// Phone alerts in the store app (migration 0390): Firebase Cloud Messaging HTTP v1. The service account here is made in
// the test (a fresh RSA key, an example.test address); nothing is a real key or project.
const b64 = (u: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(u)));
const fromB64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4)), (c) => c.charCodeAt(0));

async function account(): Promise<{ acc: FcmAccount; pub: CryptoKey; json: string }> {
  const k = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64(await crypto.subtle.exportKey('pkcs8', k.privateKey)).replace(/(.{64})/g, '$1\n')}\n-----END PRIVATE KEY-----\n`;
  const json = JSON.stringify({ type: 'service_account', project_id: 'carmacars-test', private_key_id: 'kid-1', private_key: pem,
    client_email: 'fcm-sender@carmacars-test.iam.gserviceaccount.com', token_uri: 'https://oauth2.example.test/token' });
  return { acc: parseFcmAccount(json)!, pub: k.publicKey, json };
}

test('the service account: the JSON as downloaded, or in base64; anything else is no account', async () => {
  const { acc, json } = await account();
  assert.equal(acc.project_id, 'carmacars-test');
  assert.deepEqual(parseFcmAccount(btoa(json)), acc);
  for (const bad of ['', '{}', 'not json', JSON.stringify({ ...JSON.parse(json), client_email: 'someone@example.test' }), JSON.stringify({ ...JSON.parse(json), private_key: 'x' })])
    assert.equal(parseFcmAccount(bad), null, bad.slice(0, 40));
});

test('the sign-in request is a JWT signed RS256 by the service account, for the FCM scope, valid one hour', async () => {
  const { acc, pub } = await account();
  const jwt = await fcmAssertion(acc, 1_700_000_000_000);
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromB64url(h!))), { alg: 'RS256', typ: 'JWT', kid: 'kid-1' });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromB64url(c!))), { iss: acc.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: acc.token_uri, iat: 1_700_000_000, exp: 1_700_003_600 });
  assert.equal(await crypto.subtle.verify('RSASSA-PKCS1-v1_5', pub, fromB64url(s!), new TextEncoder().encode(`${h}.${c}`)), true);
});

test('one access token per hour; a refused sign-in is an error', async () => {
  const { acc } = await account();
  resetFcmToken();
  let calls = 0;
  const ok = (async (url: string, init?: RequestInit) => {
    calls++; assert.equal(url, acc.token_uri); assert.match(String(init?.body), /^grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=[\w-]+\.[\w-]+\.[\w-]+$/);
    return Response.json({ access_token: 'token-placeholder', expires_in: 3599 });
  }) as unknown as typeof fetch;
  assert.equal(await fcmAccessToken(acc, ok, 0), 'token-placeholder');
  assert.equal(await fcmAccessToken(acc, ok, 30 * 60_000), 'token-placeholder');
  assert.equal(calls, 1, 'reused within the hour');
  await fcmAccessToken(acc, ok, 59 * 60_000);
  assert.equal(calls, 2, 'renewed in its last minute');
  resetFcmToken();
  await assert.rejects(fcmAccessToken(acc, (async () => Response.json({ error: 'invalid_grant' }, { status: 400 })) as unknown as typeof fetch), /invalid_grant/);
});

test('the message: a visible alert, its page in data.url, high priority, grouped by its notice', () => {
  const m = fcmMessage({ token: 'tok', urgent: true, payload: { title: 'Your offer is ready', body: 'CC-10001', url: '/account/bookings/CC-10001', tag: 'n-1', code: 'renter_offer_ready' } }) as Msg;
  assert.equal(m.message.token, 'tok');
  assert.deepEqual(m.message.notification, { title: 'Your offer is ready', body: 'CC-10001' });
  assert.deepEqual(m.message.data, { url: '/account/bookings/CC-10001', tag: 'n-1', code: 'renter_offer_ready' });
  assert.equal(m.message.android.priority, 'HIGH'); assert.equal(m.message.android.notification.channel_id, 'alerts'); assert.equal(m.message.android.notification.tag, 'n-1');
  assert.equal(m.message.apns.headers['apns-collapse-id'], 'n-1'); assert.equal(m.message.apns.payload.aps['interruption-level'], 'time-sensitive');
  const plain = fcmMessage({ token: 't', payload: { title: '', body: null } }) as Msg;
  assert.deepEqual(plain.message.notification, { title: 'CarmaCars' }); assert.equal(plain.message.data.url, '/');
  assert.equal(plain.message.apns.payload.aps['interruption-level'], undefined);
});

test('what Firebase\'s answer means for the device', () => {
  assert.equal(fcmOutcomeOf(200).outcome, 'sent');
  assert.equal(fcmOutcomeOf(404, { error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }).outcome, 'gone');
  assert.equal(fcmOutcomeOf(403, { error: { status: 'PERMISSION_DENIED', details: [{ errorCode: 'SENDER_ID_MISMATCH' }] } }).outcome, 'gone');
  assert.equal(fcmOutcomeOf(400, { error: { status: 'INVALID_ARGUMENT', message: 'The registration token is not a valid FCM registration token' } }).outcome, 'refused');
  for (const s of [401, 429, 500, 503]) assert.equal(fcmOutcomeOf(s, { error: { status: 'X' } }).outcome, 'retry', String(s));
  assert.match(fcmOutcomeOf(400, { error: { status: 'INVALID_ARGUMENT', message: 'bad' } }).error!, /^400 INVALID_ARGUMENT: bad/);
});

test('send: signs in once, posts to the project, and a network failure is a retry', async () => {
  const { acc } = await account();
  resetFcmToken();
  const seen: string[] = [];
  const f = (async (url: string, init?: RequestInit) => {
    seen.push(url);
    if (url === acc.token_uri) return Response.json({ access_token: 'token-placeholder', expires_in: 3600 });
    assert.equal((init?.headers as Record<string, string>).authorization, 'Bearer token-placeholder');
    return Response.json({ name: 'projects/carmacars-test/messages/1' });
  }) as unknown as typeof fetch;
  assert.deepEqual(await sendFcm({ token: 'tok', payload: { title: 'Hi' } }, acc, f), { outcome: 'sent' });
  assert.deepEqual(seen, [acc.token_uri, 'https://fcm.googleapis.com/v1/projects/carmacars-test/messages:send']);
  const down = (async () => { throw new Error('connect failed'); }) as unknown as typeof fetch;
  resetFcmToken();
  assert.deepEqual(await sendFcm({ token: 'tok', payload: {} }, acc, down), { outcome: 'retry', error: 'connect failed' });
});
