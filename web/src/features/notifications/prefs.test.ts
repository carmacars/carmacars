// Notification preferences (3260): the words and sums of the page.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyChange, channelNote, clockWords, minutesToTime, summaryLine, timeToMinutes, type PrefState } from './prefs.ts';

const state = (over: Partial<PrefState> = {}): PrefState => ({
  kind: 'user', portal: 'renter', portals: ['renter'], staff: false,
  profile: { quiet_on: false, quiet_from: 1260, quiet_until: 480, cadence: 'instant', all_off: false },
  channels: { push: { on: true, devices: 1 }, email: { on: true, address: 'maya@example.test' }, text: { on: true, why_not: null, chosen: 'both', paused: false } },
  summary: { hour: 8, weekly_dow: 1 },
  groups: [
    { name: 'Always sent', locked: true, types: [{ code: 'bookings', label: 'Booking confirmations and changes', detail: null, locked: true, channels: ['push', 'email', 'text'], live: true, push: true, email: true, text: true }] },
    { name: 'Rewards and offers', locked: false, types: [
      { code: 'rewards', label: 'Rewards, points and codes', detail: null, locked: false, channels: ['push', 'email', 'text'], live: true, push: true, email: true, text: true },
      { code: 'reviews', label: 'Review requests', detail: null, locked: false, channels: ['push', 'email', 'text'], live: true, push: false, email: false, text: false }] }
  ],
  ...over
});

test('times: minutes of the day and the time input, both ways', () => {
  assert.equal(minutesToTime(1260), '21:00');
  assert.equal(minutesToTime(480), '08:00');
  assert.equal(timeToMinutes('21:00'), 1260);
  assert.equal(timeToMinutes('7:05'), 425);
  assert.equal(timeToMinutes('24:00'), null);
  assert.equal(timeToMinutes('soon'), null);
  assert.equal(clockWords(1260), '9:00 pm');
  assert.equal(clockWords(0), '12:00 am');
  assert.equal(clockWords(725), '12:05 pm');
});

test('the summary line counts the optional kinds that are on and says when they come', () => {
  assert.equal(summaryLine(state()), '1 of 2 optional kinds are on, as they happen.');
  assert.equal(summaryLine(state({ profile: { quiet_on: true, quiet_from: 1260, quiet_until: 480, cadence: 'weekly', all_off: false } })),
    '1 of 2 optional kinds are on, in a weekly summary on Monday at 8:00 am. Quiet from 9:00 pm to 8:00 am.');
  assert.match(summaryLine(state({ profile: { quiet_on: false, quiet_from: 0, quiet_until: 0, cadence: 'instant', all_off: true } })), /Every optional notification is off/);
});

test('a channel that cannot be used says why in plain words', () => {
  assert.equal(channelNote(state(), 'text'), null);
  assert.match(channelNote(state({ channels: { ...state().channels, text: { on: false, why_not: 'no_verified_phone', chosen: null, paused: false } } }), 'text')!, /confirm a mobile number/);
  assert.match(channelNote(state({ channels: { ...state().channels, text: { on: true, why_not: null, chosen: 'both', paused: true } } }), 'text')!, /going by email right now/);
  assert.match(channelNote(state({ channels: { ...state().channels, push: { on: true, devices: 0 } } }), 'push')!, /Turn them on from the bell/);
  assert.equal(channelNote(state(), 'email'), null);
});

test('a switch moves at once; a locked type never moves; all off turns every optional one off', () => {
  const a = applyChange(state(), { type: 'rewards', channel: 'email', on: false });
  assert.equal(a.groups[1]!.types[0]!.email, false);
  assert.equal(a.groups[1]!.types[0]!.push, true);
  const b = applyChange(state(), { type: 'bookings', channel: 'email', on: false });
  assert.equal(b.groups[0]!.types[0]!.email, true);
  const c = applyChange(state(), { all_off: true });
  assert.deepEqual(c.groups[1]!.types.map((t) => [t.push, t.email, t.text]), [[false, false, false], [false, false, false]]);
  assert.equal(c.groups[0]!.types[0]!.email, true);
  const d = applyChange(c, { type: 'reviews', channel: 'push', on: true });
  assert.equal(d.profile.all_off, false);
  assert.equal(applyChange(state(), { cadence: 'daily' }).profile.cadence, 'daily');
  assert.equal(applyChange(state(), { quiet_on: true, quiet_from: 60 }).profile.quiet_from, 60);
});
