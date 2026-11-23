import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sitePath, targetFor } from './links.ts';
import { LOCK_AFTER_MS, onBackground, onForeground, onUnlocked, type LockState } from './lock.ts';
import { cancelled, createRequest, getRequest, none } from './passkey.ts';
import { addDays, ago, carName, daysBetween, money, torontoDay, when } from './format.ts';
import { packSnapshot, readSnapshot, SNAPSHOT_MAX_CHARS, SNAPSHOT_MAX_MS } from './snapshot.ts';

const J = '3f2c1a9e-77aa-4b0e-9c1d-000000000001';
test('links: pages the app has open as screens', () => {
  const screen = (href: string) => ({ kind: 'screen', href });
  assert.deepEqual(targetFor('https://carmacars.ca/cars/2023-honda-civic-lx'), screen('/car/2023-honda-civic-lx'));
  assert.deepEqual(targetFor('https://www.carmacars.ca/account/bookings/cc-1042'), screen('/trip/CC-1042'));
  assert.deepEqual(targetFor('/account/bookings/CC-1042/checkout?signed=1#pay'), screen('/trip/CC-1042/pay'));
  assert.deepEqual(targetFor('/account/bookings/CC-1042/checkout'), screen('/trip/CC-1042/sign'));
  assert.deepEqual(targetFor('/account/bookings/CC-1042/verify'), screen('/trip/CC-1042/verify'));
  assert.deepEqual(targetFor('/account/bookings/CC-1042/pickup'), screen('/trip/CC-1042/checkin'));
  assert.deepEqual(targetFor(`/staff/field/jobs/${J}`), screen(`/field/job/${J}`));
  assert.deepEqual(targetFor(`https://carmacars.ca/staff/sales-leads/${J}?from=alert`), screen(`/sales/lead/${J}`));
  assert.deepEqual(targetFor('/owner/statements/ST-1029'), screen('/owner/statement/ST-1029'));
  assert.deepEqual(targetFor('carmacars://account'), screen('/trips'));
  assert.deepEqual(targetFor('https://carmacars.ca/'), screen('/'));
});
test('links: every other page of the site opens in the in-app browser, with its query', () => {
  assert.deepEqual(targetFor('https://carmacars.ca/admin/bookings?status=on_rent'), { kind: 'web', path: '/admin/bookings?status=on_rent' });
  assert.deepEqual(targetFor('/account/bookings/CC-1042/cancel'), { kind: 'web', path: '/account/bookings/CC-1042/cancel' });
  assert.deepEqual(targetFor('/terms'), { kind: 'web', path: '/terms' });
  assert.deepEqual(targetFor('/account/profile'), { kind: 'web', path: '/account/profile' });
  assert.deepEqual(targetFor('/pay/abc123'), { kind: 'web', path: '/pay/abc123' });
});
test('links: the address the phone hands over when a link opens the app is read the same way', () => {
  // expo-router gives the whole link or only its path, depending on how the app was opened
  assert.deepEqual(targetFor('https://carmacars.ca/account/bookings/CC-1042/checkout#pay'), { kind: 'screen', href: '/trip/CC-1042/pay' });
  assert.deepEqual(targetFor('/staff/field'), { kind: 'screen', href: '/field' });
  assert.deepEqual(targetFor('carmacars://staff/sales-leads'), { kind: 'screen', href: '/leads' });
  assert.deepEqual(targetFor('carmacars://'), { kind: 'screen', href: '/' });
});
test('links: another site, a look-alike host, plain http and script URLs go nowhere', () => {
  for (const bad of ['https://evil.example.test/account', 'https://carmacars.ca.evil.example.test/account', 'https://carmacars.ca@evil.example.test/', 'http://carmacars.ca/account', 'javascript:alert(1)',
    '//evil.example.test/x', '/\\evil.example.test', 'https://carmacars.ca/a b', '', null]) assert.equal(targetFor(bad), null, String(bad));
  assert.equal(sitePath('https://carmacars.ca/cars?x=1#y'), '/cars?x=1#y');
});

const lock = (o: Partial<LockState> = {}): LockState => ({ enabled: true, signedIn: true, locked: false, backgroundAt: null, ...o });
test('app lock: locks after five minutes away and at a cold start, only when it is on and someone is signed in', () => {
  const t = 1_000_000;
  const away = (ms: number, s = lock()) => onForeground(onBackground(s, t), t + ms);
  assert.equal(away(LOCK_AFTER_MS - 1).locked, false);
  assert.equal(away(LOCK_AFTER_MS).locked, true);
  assert.equal(away(LOCK_AFTER_MS, lock({ enabled: false })).locked, false);
  assert.equal(away(LOCK_AFTER_MS, lock({ signedIn: false })).locked, false);
  assert.equal(onForeground(lock(), t, true).locked, true);
  assert.equal(onForeground(lock({ enabled: false }), t, true).locked, false);
  // the phone's clock moved backwards while away: locked, not trusted
  assert.equal(onForeground(onBackground(lock(), t), t - 5000).locked, true);
  // the first time in the background is the one that counts (a second "inactive" event does not reset it)
  assert.equal(onForeground(onBackground(onBackground(lock(), t), t + LOCK_AFTER_MS), t + LOCK_AFTER_MS + 1).locked, true);
  assert.equal(onUnlocked(away(LOCK_AFTER_MS)).locked, false);
  // still locked when the app is opened again without unlocking
  assert.equal(onForeground(lock({ locked: true }), t).locked, true);
});

test('passkeys: the phone is asked for a key bound to the site, kept on the phone, with the screen lock', () => {
  const o = { challenge_id: 'c1', challenge: 'abc_-', rp_id: 'carmacars.ca', rp_name: 'CarmaCars', user: { id: J, name: 'rita@example.test', display_name: 'Rita Renter' }, exclude: ['cred1'] };
  const c = createRequest(o);
  assert.equal(c.rp.id, 'carmacars.ca');
  assert.equal(c.authenticatorSelection.userVerification, 'required');
  assert.equal(c.authenticatorSelection.residentKey, 'required');
  assert.deepEqual(c.excludeCredentials, [{ type: 'public-key', id: 'cred1' }]);
  assert.equal(Buffer.from(c.user.id, 'base64url').toString(), J);
  assert.match(c.user.id, /^[A-Za-z0-9_-]+$/);
  assert.deepEqual(getRequest(o), { challenge: 'abc_-', rpId: 'carmacars.ca', timeout: 120_000, userVerification: 'required' });
  assert.throws(() => createRequest({ ...o, user: undefined }));
  assert.equal(cancelled({ error: 'UserCancelled' }), true);
  assert.equal(cancelled(new Error('The server refused')), false);
  assert.equal(none({ error: 'NoCredentials' }), true);
});

test('words: money, Toronto time whatever the phone\'s zone, and ages', () => {
  assert.equal(money(12345), '$123.45');
  assert.equal(money(120000), '$1,200');
  assert.equal(money(-500), '-$5');
  assert.equal(money(null), '');
  assert.match(when('2026-11-20T15:00:00Z'), /^Fri, Nov 20, 10:00 a\.m\.$/);
  assert.equal(when('2026-11-21T03:30:00Z', false), 'Fri, Nov 20');
  assert.equal(torontoDay(new Date('2026-11-21T03:30:00Z')), '2026-11-20');
  assert.equal(addDays('2026-11-30', 2), '2026-12-02');
  assert.equal(daysBetween('2026-11-20', '2026-11-24'), 4);
  assert.equal(carName({ vehicle_year: 2023, vehicle_make: 'Honda', vehicle_model: 'Civic' }), '2023 Honda Civic');
  assert.equal(ago('2026-11-20T15:00:00Z', Date.parse('2026-11-20T15:12:00Z')), '12 min ago');
});

test('launch snapshot: shown at once only when it is the same shape, recent, and the same person (r49, reel 7)', () => {
  const now = Date.UTC(2026, 10, 23, 15);
  const me = { user: { id: 'u1' }, roles: { renter: true } };
  const raw = packSnapshot(me, 'u1', now)!;
  assert.deepEqual(readSnapshot(raw, now + 1000, 'u1'), me);
  assert.equal(readSnapshot(raw, now + 1000, 'u2'), null, 'another person never sees the last account');
  assert.equal(readSnapshot(raw, now + 1000, null), null, 'signed out: no account');
  assert.equal(readSnapshot(raw, now + SNAPSHOT_MAX_MS + 1, 'u1'), null, 'too old: wait for the server');
  assert.equal(readSnapshot(raw.replace('"v":1', '"v":0'), now, 'u1'), null);
  assert.equal(readSnapshot('not json', now), null);
  assert.equal(readSnapshot(null, now), null);
  const cfg = { brand: 'CarmaCars' };
  assert.deepEqual(readSnapshot(packSnapshot(cfg, null, now), now), cfg, 'the settings are read whoever is signed in');
  assert.equal(packSnapshot({ big: 'x'.repeat(SNAPSHOT_MAX_CHARS) }, null, now), null, 'too big to keep');
});
