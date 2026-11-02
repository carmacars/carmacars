import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deviceLabel, isIos, storeLink, supportOf, topicLabel, topicsFor, TOPICS } from './topics.ts';

// Phone and browser alerts (migration 0300): the card's words and the browser facts it reads.
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
const IPAD_DESKTOP = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15';
const ANDROID = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const WIN_EDGE = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0';

test('a short name for each device', () => {
  assert.equal(deviceLabel(IPHONE), 'iPhone, Safari');
  assert.equal(deviceLabel(ANDROID), 'Android phone, Chrome');
  assert.equal(deviceLabel(WIN_EDGE), 'Windows, Edge');
  assert.equal(deviceLabel(IPAD_DESKTOP), 'Mac, Safari');
  assert.equal(deviceLabel(''), 'Device');
});

test('iOS needs the Home Screen first; a blocked permission and an old browser say so', () => {
  assert.equal(isIos(IPHONE), true);
  assert.equal(isIos(IPAD_DESKTOP, 5), true, 'an iPad that asks for the desktop site');
  assert.equal(isIos(IPAD_DESKTOP, 0), false, 'a Mac');
  assert.equal(supportOf({ ua: IPHONE, standalone: false, hasPush: false, permission: 'none' }), 'ios_install');
  assert.equal(supportOf({ ua: IPHONE, standalone: true, hasPush: true, permission: 'default' }), 'ready');
  assert.equal(supportOf({ ua: ANDROID, standalone: false, hasPush: true, permission: 'denied' }), 'blocked');
  assert.equal(supportOf({ ua: ANDROID, standalone: false, hasPush: false, permission: 'none' }), 'unsupported');
  assert.equal(supportOf({ ua: WIN_EDGE, standalone: false, hasPush: true, permission: 'granted' }), 'ready');
});

test('each portal words the topics for its people, and shows only the ones that reach them', () => {
  assert.equal(topicLabel('owner', 'requests').label, 'New bookings of your cars');
  assert.equal(topicLabel('admin', 'requests').label, 'New requests and offers');
  assert.equal(topicLabel('field', 'handovers').label, 'My jobs');
  assert.deepEqual(topicsFor('investor'), ['payments', 'documents', 'messages']);
  assert.equal(topicsFor('renter').length, 7, 'renters never see the staff topics');
  assert.deepEqual(topicsFor('admin').slice(-2), ['leads', 'visitors']);
  assert.deepEqual(topicsFor('staff').slice(-2), ['leads', 'visitors']);
  assert.ok(!topicsFor('field').includes('leads') && !topicsFor('owner').includes('visitors'));
  assert.equal(topicLabel('admin', 'leads').label, 'New leads');
  for (const t of TOPICS) assert.ok(!/[–—]/.test(topicLabel('renter', t).label + topicLabel('renter', t).hint), 'no long dashes');
});

test('the download prompt replaces browser alerts on phones once the app is published; desktop and the app itself are unchanged', () => {
  const store = { ios: 'https://apps.example.test/ios', android: 'https://play.example.test/app' };
  assert.equal(storeLink(IPHONE, store)?.url, store.ios);
  assert.equal(storeLink(ANDROID, store)?.platform, 'android');
  assert.equal(storeLink(WIN_EDGE, store), null, 'desktop keeps browser alerts');
  assert.equal(storeLink(IPHONE, { ios: null, android: store.android }), null, 'empty until published');
  assert.equal(storeLink(IPHONE + ' CarmaCarsApp/1.0', store), null, 'inside the app the native prompt is used');
  assert.equal(storeLink(IPHONE, undefined), null);
});
