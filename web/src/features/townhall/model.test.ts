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
