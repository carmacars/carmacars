import { test } from 'node:test';
import assert from 'node:assert/strict';
import { releasesOfWeek, townhallIcs, withReleases, type Slide } from './model.ts';

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
