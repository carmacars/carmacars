import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { clampDay, isDay, joinLocal, normalize, pretty, splitLocal, timeOptions } from './date-input.ts';

describe('shared date fields', () => {
  it('knows a real day', () => {
    assert.equal(isDay('2026-11-07'), true); assert.equal(isDay('2026-02-30'), false); assert.equal(isDay('2026-1-7'), false); assert.equal(isDay(''), false);
    assert.equal(isDay('2028-02-29'), true); assert.equal(isDay('2027-02-29'), false);
  });
  it('keeps a typed value only when it is complete', () => {
    assert.equal(normalize('date', ' 2026-11-07 '), '2026-11-07'); assert.equal(normalize('date', '2026-11'), '');
    assert.equal(normalize('datetime-local', '2026-09-02T14:00'), '2026-09-02T14:00'); assert.equal(normalize('datetime-local', '2026-09-02 14:00'), '2026-09-02T14:00');
    assert.equal(normalize('datetime-local', '2026-09-02'), ''); assert.equal(normalize('time', '09:45'), '09:45'); assert.equal(normalize('time', '25:00'), '');
  });
  it('splits and joins a day and a time', () => {
    assert.deepEqual(splitLocal('2026-11-07T14:30'), { day: '2026-11-07', time: '14:30' });
    assert.deepEqual(splitLocal('2026-11-07'), { day: '2026-11-07', time: '' });
    assert.equal(joinLocal('2026-11-07', ''), '2026-11-07T09:00'); assert.equal(joinLocal('', '10:00'), '');
  });
  it('words for the field', () => {
    assert.equal(pretty('date', '2026-11-07'), 'Nov 7, 2026');
    assert.equal(pretty('datetime-local', '2026-11-07T14:30'), 'Nov 7, 2026, 2:30 p.m.');
    assert.equal(pretty('datetime-local', '2026-11-07T00:00'), 'Nov 7, 2026, 12:00 a.m.');
    assert.equal(pretty('time', '13:15'), '1:15 p.m.'); assert.equal(pretty('date', ''), '');
  });
  it('time options every 15 minutes, keeping an off-grid value', () => {
    const t = timeOptions(15); assert.equal(t.length, 96); assert.equal(t[0], '00:00'); assert.equal(t[95], '23:45'); assert.equal(t[5], '01:15');
    assert.equal(timeOptions(15, '10:07').includes('10:07'), true); assert.equal(timeOptions(15, '10:15').length, 96);
  });
  it('clamps a day into the range', () => {
    assert.equal(clampDay('2026-01-01', '2026-02-01', '2026-03-01'), '2026-02-01'); assert.equal(clampDay('2026-05-01', '2026-02-01', '2026-03-01'), '2026-03-01'); assert.equal(clampDay('2026-02-10'), '2026-02-10');
  });
});
