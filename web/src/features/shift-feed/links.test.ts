import { test } from 'node:test';
import assert from 'node:assert/strict';
import { feedUrl, googleAddUrl, webcalUrl } from './links.ts';

const T = 'a'.repeat(64);

test('the feed address ends in .ics under /api/shift-feed', () => {
  assert.equal(feedUrl('https://carmacars.ca/', T), `https://carmacars.ca/api/shift-feed/${T}.ics`);
});

test('a token that is not 64 hex characters is refused', () => {
  assert.throws(() => feedUrl('https://carmacars.ca', 'abc'));
  assert.throws(() => feedUrl('https://carmacars.ca', 'A'.repeat(64)));
});

test('webcal and the one-click Google link carry the url-encoded webcal address', () => {
  const u = feedUrl('https://carmacars.ca', T);
  assert.equal(webcalUrl(u), `webcal://carmacars.ca/api/shift-feed/${T}.ics`);
  assert.equal(googleAddUrl(u), `https://calendar.google.com/calendar/r?cid=${encodeURIComponent(`webcal://carmacars.ca/api/shift-feed/${T}.ics`)}`);
  assert.match(googleAddUrl(u), /cid=webcal%3A%2F%2Fcarmacars\.ca%2Fapi%2Fshift-feed%2Fa{64}\.ics$/);
});
