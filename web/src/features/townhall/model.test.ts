import { test } from 'node:test';
import assert from 'node:assert/strict';
import { moveNotice, releasesOfWeek, townhallIcs, withReleases, type Slide } from './model.ts';

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

test('1068: the notice of the move to the least busy day, 7 days ahead, and none when the day stays', () => {
  assert.equal(moveNotice({ weekday: 1, next_weekday: 2, next_from: '2026-11-17' }), 'From Tuesday, November 17 the townhall is on Tuesdays (the least busy day of the last 8 weeks and the next 2).');
  assert.equal(moveNotice({ weekday: 2, next_weekday: 2, next_from: '2026-11-17' }), null);
  assert.equal(moveNotice({ weekday: 1, next_weekday: null, next_from: null }), null);
});
