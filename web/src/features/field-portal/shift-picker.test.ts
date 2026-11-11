// The shift picker (r35 part SP, 1770): the availability grid, its words, the minimum and the week view.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ALL_CELLS, addDays, availabilityWords, buildWeek, dayCells, halfHours, isoDow, minimumWords, partCells, toggleCell, toggleMany, torontoDay } from './shift-picker.ts';

test('the grid: 21 cells as the database stores them, toggled in grid order', () => {
  assert.equal(ALL_CELLS.length, 21);
  assert.equal(ALL_CELLS[0], '1:am');
  assert.deepEqual(toggleCell(['6:pm'], '1:am'), ['1:am', '6:pm']);
  assert.deepEqual(toggleCell(['1:am', '6:pm'], '1:am'), ['6:pm']);
  assert.deepEqual(toggleMany([], dayCells(6)), ['6:am', '6:pm', '6:eve']);
  assert.deepEqual(toggleMany(dayCells(6), dayCells(6)), []);
  assert.deepEqual(toggleMany(['1:am'], partCells('am')).length, 7);
});

test('the grid in words', () => {
  assert.equal(availabilityWords([]), 'Not given');
  assert.equal(availabilityWords(ALL_CELLS), 'Any time');
  assert.equal(availabilityWords([...partCells('am').slice(0, 5), ...dayCells(6), ...dayCells(7)]), 'Mon to Fri morning; Sat, Sun all day');
  assert.equal(availabilityWords(['1:pm', '3:pm', '3:eve']), 'Mon afternoon; Wed afternoon and evening');
});

test('half hours for a standing shift and the minimum in words', () => {
  const h = halfHours();
  assert.deepEqual(h[0], ['05:00', '5:00 AM']);
  assert.deepEqual(h.find((x) => x[0] === '18:00'), ['18:00', '6:00 PM']);
  assert.deepEqual(h[h.length - 1], ['23:30', '11:30 PM']);
  assert.deepEqual(minimumWords({ min: 2, ahead: 7, claimed: 1 }), { text: '1 of 2 shifts claimed for the next 7 days', met: false, off: false });
  assert.equal(minimumWords({ min: 2, ahead: 7, claimed: 3 }).met, true);
  assert.equal(minimumWords({ min: 0, ahead: 7, claimed: 0 }).off, true);
});

test('the week view: seven Toronto days, items in time order, mine first', () => {
  const now = Date.parse('2026-11-11T15:00:00Z'); // Wednesday in Toronto
  assert.equal(torontoDay('2026-11-12T03:00:00Z'), '2026-11-11'); // 10 PM in Toronto
  assert.equal(addDays('2026-11-30', 1), '2026-12-01');
  assert.equal(isoDow('2026-11-14'), 6);
  const w = buildWeek([
    { kind: 'open', id: 'o', starts_at: '2026-11-14T15:00:00Z', ends_at: '2026-11-14T23:00:00Z' },
    { kind: 'mine', id: 'm', starts_at: '2026-11-14T15:00:00Z', ends_at: '2026-11-14T23:00:00Z' },
    { kind: 'offer', id: 'x', starts_at: '2026-11-25T15:00:00Z', ends_at: '2026-11-25T23:00:00Z' }], now);
  assert.equal(w.length, 7);
  assert.equal(w[0]!.day, '2026-11-11');
  assert.equal(w[0]!.today, true);
  assert.deepEqual(w[3]!.items.map((i) => i.id), ['m', 'o']);
  assert.equal(buildWeek([{ kind: 'offer', id: 'x', starts_at: '2026-11-25T15:00:00Z', ends_at: '2026-11-25T23:00:00Z' }], now, 2)[0]!.items.length, 1);
});
