import { test } from 'node:test';
import assert from 'node:assert/strict';
import { visitorDays, releasesOfWeek, townhallIcs, withReleases, type Slide } from './model.ts';

test('1062: the platform updates of the week, and the weekly invite', () => {
  const list = [{ release: 'r33', title: 'Release 33', date: '2026-11-08', summary: 'A' }, { release: 'r34', title: 'Release 34', date: '2026-11-09', summary: 'B' }, { release: 'r35', title: 'Release 35', date: 'pending', summary: 'C' }];
  assert.deepEqual(releasesOfWeek(list, '2026-11-02').map((r) => r.release), ['r33']);
  assert.deepEqual(releasesOfWeek(list, '2026-11-09').map((r) => r.release), ['r34']);
  const s: Slide[] = [{ key: 'dev', title: 'Platform updates', admin_only: false, points: [] }];
  assert.deepEqual(withReleases(s, [])[0]!.lines, ['No release shipped this week.']);
  const ics = townhallIcs({ nextAt: '2026-11-09T16:30:00Z', minutes: 45, url: 'https://meet.example.test/x', base: 'https://carmacars.ca' });
  assert.match(ics, /DTSTART:20261109T163000Z/);
  assert.match(ics, /DTEND:20261109T171500Z/);
  assert.match(ics, /RRULE:FREQ=WEEKLY/);
});

test('1068: the visitor sessions per weekday, Monday first, the quietest marked; none without data', () => {
  const r = visitorDays({ 1: 40, 2: 35, 3: 20, 4: 33, 5: 38, 6: 25, 7: 20 });
  assert.equal(r.map((x) => `${x.name}=${x.sessions}${x.quietest ? '*' : ''}`).join(' '), 'Monday=40 Tuesday=35 Wednesday=20* Thursday=33 Friday=38 Saturday=25 Sunday=20*');
  assert.deepEqual(visitorDays(null), []);
  assert.equal(visitorDays({ 1: 0 }).some((x) => x.quietest), false);
});

test('1505: the run clock gives each section its start minute', async () => {
  const { runClock } = await import('./model.ts');
  assert.deepEqual(runClock([{ key: 'a', title: 'A', admin_only: false, points: [], minutes: 1 }, { key: 'b', title: 'B', admin_only: false, points: [], minutes: 2 }, { key: 'c', title: 'C', admin_only: true, points: [] }]), [0, 1, 3]);
});

test('2590: the townhall card: from the day before until the end, Join from 15 minutes before, the warning after a miss', async () => {
  const { townhallCard, countdown } = await import('./model.ts');
  const at = Date.parse('2026-11-18T18:00:00Z'); // Wednesday 1:00 pm Toronto
  const v = { has_link: true, next_at: '2026-11-18T18:00:00Z', minutes: 30, live: false, card: true, ends_at: '2026-11-18T18:30:00Z', checked_in: false, missed_last: true };
  assert.equal(townhallCard({ ...v, card: false }, at - 86_400_000), null);
  const dayBefore = townhallCard(v, at - 24 * 3_600_000)!;
  assert.equal(dayBefore.headline, 'Townhall tomorrow');
  assert.equal(dayBefore.joinOpen, false);
  assert.equal(dayBefore.warn, 'You missed the last townhall: one more miss locks your account.');
  const morning = townhallCard({ ...v, missed_last: false }, at - 4 * 3_600_000)!;
  assert.equal(morning.headline, 'Townhall today');
  assert.equal(morning.countdown, 'in 4 h');
  assert.equal(morning.warn, null);
  assert.equal(townhallCard(v, at - 16 * 60_000)!.joinOpen, false);
  assert.equal(townhallCard(v, at - 15 * 60_000)!.joinOpen, true);
  const on = townhallCard(v, at + 5 * 60_000)!;
  assert.equal(on.live, true);
  assert.equal(on.headline, 'The townhall is on now');
  assert.equal(townhallCard(v, at + 30 * 60_000), null);
  assert.equal(countdown(12 * 60_000), 'in 12 min');
  assert.equal(countdown(125 * 60_000), 'in 2 h 5 min');
  assert.equal(countdown(0), 'now');
});

test('a past townhall in words: held, or not held with nobody absent (r45, 2863)', async () => {
  const { meetingWords } = await import('./model.ts');
  assert.equal(meetingWords({ meeting_at: '', held: true, reason: null, missed: 1, attended: 6 }), 'held: 6 there, 1 missed');
  assert.equal(meetingWords({ meeting_at: '', held: false, reason: 'Nobody attended: recorded as not held', missed: 0, attended: 0 }), 'not held (Nobody attended: recorded as not held): nobody counts as absent');
});
