// Unit tests for calendar sync's iCal reader and run (ical.ts and sync-run.ts, migration 0062): the sample feeds in the shapes Turo, Getaround and Google Calendar write (folded lines, UTC times, all-day
// dates across the end of daylight saving, TZID with a VTIMEZONE block, DURATION, free and cancelled events, a weekly
// rule with EXDATE and a moved occurrence, an Outlook zone name, a floating time), errors in plain words, and one run
// with a mocked database and platform (not modified, 404, a web page in place of a calendar, a private address).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { IcalError, parseDuration, parseIcal, resolveZone, unfold, zonedToUtc } from './ical.ts';
import { httpReason, normalizeUrl, privateHost, syncDue, syncOne, type DueFeed, type Store } from './sync-run.ts';

const SAMPLES = join(import.meta.dirname, 'samples');
const sample = (f: string) => readFileSync(join(SAMPLES, f), 'utf8');
const NOW = new Date('2026-10-19T12:00:00Z');
const brief = (r: ReturnType<typeof parseIcal>) => r.events.map((e) => `${e.starts_at.slice(0, 16)} ${e.ends_at.slice(0, 16)} ${e.all_day ? 'D' : 'T'} ${e.summary}`);

test('Turo: UTC trips kept, a folded description read, an all-day block across the end of daylight saving, ended and cancelled trips left out', () => {
  const r = parseIcal(sample('turo.ics'), { now: NOW });
  assert.equal(r.calendar_name, '2024 Mercedes-Benz C 300 (Turo)');
  assert.match(r.prodid ?? '', /Turo/);
  assert.deepEqual(brief(r), [
    '2026-10-23T14:00 2026-10-25T14:00 T Turo trip',
    // Nov 1 midnight in Toronto is still daylight time (04:00 UTC); Nov 3 midnight is standard time (05:00 UTC)
    '2026-11-01T04:00 2026-11-03T05:00 D Unavailable'
  ]);
  assert.equal(r.events[0]!.uid, 'trip-48211907@turo.com');
});

test('Getaround: TZID times with a VTIMEZONE block and an alarm inside the event, DURATION, a free event left out', () => {
  const r = parseIcal(sample('getaround.ics'), { now: NOW });
  assert.equal(r.calendar_name, 'Getaround: Kia K5');
  assert.deepEqual(brief(r), [
    '2026-10-31T22:00 2026-11-01T23:00 T Getaround booking', // 18:00 EDT to 18:00 EST: 25 hours
    '2026-11-05T14:00 2026-11-05T19:00 T Getaround booking'
  ]);
  assert.deepEqual(r.warnings, []);
});

test('Google: a weekly rule on two days with COUNT, EXDATE and a moved occurrence; an Outlook zone name; a floating time in Toronto', () => {
  const r = parseIcal(sample('google.ics'), { now: NOW });
  assert.deepEqual(brief(r), [
    '2026-10-21T12:00 2026-10-21T16:00 T Owner, personal use',
    '2026-10-28T14:00 2026-10-28T18:00 T Owner, personal use (moved)',
    '2026-10-31T12:00 2026-10-31T16:00 T Owner, personal use',
    '2026-11-02T17:00 2026-11-02T19:00 T Outlook zone',
    '2026-11-03T14:00 2026-11-03T15:00 T Floating time',
    '2026-11-04T13:00 2026-11-04T17:00 T Owner, personal use', // 08:00 EST after the change
    '2026-11-07T13:00 2026-11-07T17:00 T Owner, personal use'
  ]);
  const uids = r.events.map((e) => e.uid);
  assert.equal(new Set(uids).size, uids.length, 'every occurrence has its own uid');
  assert.ok(uids.includes('weekly-owner@google.com'), 'the first occurrence keeps the plain uid');
  assert.ok(uids.some((u) => u.startsWith('weekly-owner@google.com#2026-10-28')), 'the moved occurrence is named by its original time');
});

test('time zones: Toronto across both changes, an unknown zone read in Toronto with a warning, Windows names', () => {
  assert.equal(new Date(zonedToUtc(2026, 7, 1, 10, 0, 0, 'America/Toronto')).toISOString(), '2026-07-01T14:00:00.000Z');
  assert.equal(new Date(zonedToUtc(2026, 12, 1, 10, 0, 0, 'America/Toronto')).toISOString(), '2026-12-01T15:00:00.000Z');
  // 02:30 on March 8, 2026 does not exist in Toronto: read as the hour after the change
  assert.equal(new Date(zonedToUtc(2026, 3, 8, 2, 30, 0, 'America/Toronto')).toISOString(), '2026-03-08T07:30:00.000Z');
  assert.equal(resolveZone('Eastern Standard Time'), 'America/Toronto');
  assert.equal(resolveZone('/mozilla.org/20050126_1/America/New_York'), 'America/New_York');
  assert.equal(resolveZone('Mars/Olympus'), null);
  const r = parseIcal('BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nDTSTART;TZID=Mars/Olympus:20261020T100000\nDTEND;TZID=Mars/Olympus:20261020T120000\nEND:VEVENT\nEND:VCALENDAR', { now: NOW });
  assert.equal(r.events[0]!.starts_at, '2026-10-20T14:00:00.000Z');
  assert.match(r.warnings[0]!, /Unknown time zone/);
});

test('all-day: one date alone is one day; a multi-day event; a daily rule of dates', () => {
  const one = parseIcal('BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20261120\nSUMMARY:Service\nEND:VEVENT\nEND:VCALENDAR', { now: NOW });
  assert.deepEqual(brief(one), ['2026-11-20T05:00 2026-11-21T05:00 D Service']);
  const daily = parseIcal('BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:d\nDTSTART;VALUE=DATE:20261030\nDTEND;VALUE=DATE:20261031\nRRULE:FREQ=DAILY;COUNT=4\nSUMMARY:Away\nEND:VEVENT\nEND:VCALENDAR', { now: NOW });
  assert.deepEqual(daily.events.map((e) => e.starts_at.slice(0, 16)), ['2026-10-30T04:00', '2026-10-31T04:00', '2026-11-01T04:00', '2026-11-02T05:00']);
  assert.equal(daily.events[2]!.ends_at.slice(0, 16), '2026-11-02T05:00', 'the day of the change is 25 hours long');
});

test('lines, durations and errors', () => {
  assert.deepEqual(unfold('A:1\r\n B\r\n\tC\r\nD:2'), ['A:1BC', 'D:2']);
  assert.equal(parseDuration('PT1H30M'), 5_400_000);
  assert.equal(parseDuration('P1W'), 7 * 86_400_000);
  assert.equal(parseDuration('nonsense'), null);
  assert.throws(() => parseIcal('<!doctype html><html><body>Sign in</body></html>'), (e: unknown) => e instanceof IcalError && /web page/.test((e as Error).message));
  assert.throws(() => parseIcal('{"error": "nope"}'), IcalError);
  const r = parseIcal('BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:z\nDTSTART:20261020T100000Z\nDTEND:20261020T100000Z\nEND:VEVENT\nEND:VCALENDAR', { now: NOW });
  assert.equal(r.events.length, 0);
  assert.match(r.warnings[0]!, /no length/);
  // no uid: one is made from the start and the title, the same each time
  const a = parseIcal('BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20261020T100000Z\nDTEND:20261020T110000Z\nSUMMARY:X\nEND:VEVENT\nEND:VCALENDAR', { now: NOW });
  const b = parseIcal('BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20261020T100000Z\nDTEND:20261020T110000Z\nSUMMARY:X\nEND:VEVENT\nEND:VCALENDAR', { now: NOW });
  assert.equal(a.events[0]!.uid, b.events[0]!.uid);
});

test('links: webcal is https, private addresses refused, reasons in words', () => {
  assert.equal(normalizeUrl(' webcal://turo.com/ical/abc.ics '), 'https://turo.com/ical/abc.ics');
  for (const u of ['http://localhost:3000/x', 'http://127.0.0.1/x', 'http://10.0.0.5/x', 'http://192.168.1.2/x', 'http://172.20.0.1/x', 'http://[::1]/x', 'http://metadata.internal/x'])
    assert.equal(privateHost(u), true, u);
  assert.equal(privateHost('https://turo.com/ical/abc.ics'), false);
  assert.match(httpReason(404), /not found.*Copy it again/);
  assert.match(httpReason(503), /tried again/);
});

function mockStore(due: DueFeed[]) {
  const calls: Array<[string, string, unknown]> = [];
  const store: Store = {
    async due() { return due; },
    async ok(id, events, meta) { calls.push(['ok', id, { events: events === null ? null : events.length, meta }]); return { added: events?.length ?? 0 }; },
    async failed(id, error) { calls.push(['failed', id, error]); return { failures: 1 }; }
  };
  return { store, calls };
}

test('one run: parsed events to the database, not modified, 404, a web page, a private address, a link that cannot be reached', async () => {
  const feeds: DueFeed[] = [
    { id: 'f1', url: 'webcal://turo.example/ical/1.ics', platform: 'turo', etag: null, last_modified: null },
    { id: 'f2', url: 'https://ga.example/cal.ics', platform: 'getaround', etag: '"v7"', last_modified: null },
    { id: 'f3', url: 'https://turo.example/ical/gone.ics', platform: 'turo', etag: null, last_modified: null },
    { id: 'f4', url: 'https://other.example/page', platform: 'other', etag: null, last_modified: null },
    { id: 'f5', url: 'http://192.168.0.10/cal.ics', platform: 'other', etag: null, last_modified: null }
  ];
  const { store, calls } = mockStore(feeds);
  const seen: Array<{ url: string; headers: Record<string, string> }> = [];
  const f = async (url: string, init: RequestInit) => {
    seen.push({ url, headers: init.headers as Record<string, string> });
    if (url.includes('/1.ics')) return new Response(sample('turo.ics'), { status: 200, headers: { etag: '"t1"' } });
    if (url.includes('ga.example')) return new Response(null, { status: 304 });
    if (url.includes('gone')) return new Response('nope', { status: 404 });
    return new Response('<html><body>Sign in</body></html>', { status: 200 });
  };
  const r = await syncDue(store, f, { now: NOW, parallel: 2 });
  assert.equal(`${r.feeds} ${r.ok} ${r.failed}`, '5 2 3');
  assert.equal(seen[0]!.url, 'https://turo.example/ical/1.ics', 'webcal read as https');
  assert.equal(seen.find((s) => s.url.includes('ga.example'))!.headers['If-None-Match'], '"v7"', 'the last etag is sent');
  assert.ok(!seen.some((s) => s.url.includes('192.168')), 'a private address is never fetched');
  const byId = Object.fromEntries(calls.map((c) => [c[1], c]));
  assert.deepEqual(byId.f1, ['ok', 'f1', { events: 2, meta: { etag: '"t1"', last_modified: null, calendar_name: '2024 Mercedes-Benz C 300 (Turo)', warnings: [] } }]);
  assert.equal((byId.f2![2] as { events: null }).events, null, 'not modified: nothing to replace');
  assert.match(byId.f3![2] as string, /404 \(not found\)/);
  assert.match(byId.f4![2] as string, /web page, not a calendar/);
  assert.match(byId.f5![2] as string, /cannot be read from the server/);
  // a platform that cannot be reached: recorded as a failure in words
  const down = mockStore([]);
  const one = await syncOne({ id: 's', url: 'https://down.example/c.ics', platform: 'other', etag: null, last_modified: null }, down.store,
    async () => { throw new Error('getaddrinfo ENOTFOUND down.example'); });
  assert.match(down.calls[0]![2] as string, /could not be reached \(getaddrinfo ENOTFOUND/);
  assert.equal(one.ok, false);
});
