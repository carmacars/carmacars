import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { addYears, clampDay, expiryRange, isDay, joinLocal, maskDay, normalize, openDay, pretty, splitLocal, timeOptions } from './date-input.ts';

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
  // hotfix-date (CC-10599): a renter could not type the policy expiry on a phone (the number pad has no dash), and the
  // calendar opened on a far month instead of today's
  it('takes a day typed with digits only, or with other separators', () => {
    assert.equal(maskDay('2027'), '2027'); assert.equal(maskDay('20270'), '2027-0'); assert.equal(maskDay('202701'), '2027-01');
    assert.equal(maskDay('2027011'), '2027-01-1'); assert.equal(maskDay('20270115'), '2027-01-15'); assert.equal(maskDay('2027-011'), '2027-01-1');
    assert.equal(maskDay('2027-01-15'), '2027-01-15'); assert.equal(maskDay('2027/1/5'), '2027-01-5'); assert.equal(maskDay('2027.01.15'), '2027-01-15');
    assert.equal(maskDay('2027-1-'), '2027-01'); assert.equal(maskDay('2027-'), '2027'); assert.equal(maskDay('15/01/2027'), '15/01/2027'); assert.equal(maskDay('Jan 15'), 'Jan 15');
    assert.equal(normalize('date', '20270115'), '2027-01-15'); assert.equal(normalize('date', '2027/01/15'), '2027-01-15'); assert.equal(normalize('date', '2027013'), '');
  });
  it('opens the calendar on the value, else today kept in range', () => {
    assert.equal(openDay('2027-03-04', '2026-11-23', '2026-11-23', '2029-11-23'), '2027-03-04');
    assert.equal(openDay('', '2026-11-23', '2026-11-23', '2029-11-23'), '2026-11-23');
    assert.equal(openDay('', '2026-11-23', '2027-01-01', '2029-11-23'), '2027-01-01');
    assert.equal(openDay('2027-1', '2026-11-23', undefined, undefined), '2026-11-23');
  });
  it('an expiry runs from today (or a later first day) to some years on', () => {
    assert.equal(addYears('2026-11-23', 3), '2029-11-23'); assert.equal(addYears('2028-02-29', 1), '2029-02-28');
    assert.deepEqual(expiryRange('2026-11-23', 3), { min: '2026-11-23', max: '2029-11-23' });
    assert.deepEqual(expiryRange('2026-11-23', 3, '2027-01-01'), { min: '2027-01-01', max: '2029-11-23' });
    assert.deepEqual(expiryRange('2026-11-23', 3, '2030-06-01'), { min: '2030-06-01', max: '2031-06-01' });
  });
});
