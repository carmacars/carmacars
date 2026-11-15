import { test } from 'node:test';
import assert from 'node:assert/strict';
import { birthdayProblem, holidayRule, pct } from './occasions.ts';

test('holiday rules read as people say them', () => {
  assert.equal(holidayRule({ kind: 'fixed', month: 12, day: 25, isodow: null, nth: null, offset_days: 0 }), 'December 25');
  assert.equal(holidayRule({ kind: 'nth_weekday', month: 2, day: null, isodow: 1, nth: 3, offset_days: 0 }), '3rd Monday of February');
  assert.equal(holidayRule({ kind: 'weekday_before', month: 5, day: 25, isodow: 1, nth: null, offset_days: 0 }), 'Monday before May 25');
  assert.equal(holidayRule({ kind: 'easter', month: null, day: null, isodow: null, nth: null, offset_days: -2 }), 'Easter Sunday, 2 days before');
});

test('percents from basis points', () => {
  assert.equal(pct(1000), '10%');
  assert.equal(pct(1250), '12.5%');
  assert.equal(pct(0), 'Off');
});

test('a birthday: month and day, the year optional', () => {
  assert.equal(birthdayProblem('', '', ''), null);
  assert.equal(birthdayProblem('5', '5', ''), null);
  assert.equal(birthdayProblem('2', '29', ''), null);
  assert.equal(birthdayProblem('2', '30', ''), 'February has days 1 to 29.');
  assert.equal(birthdayProblem('', '4', ''), 'Choose the month.');
  assert.equal(birthdayProblem('2', '29', '1991', 2026), '1991 has no February 29.');
  assert.equal(birthdayProblem('2', '29', '1992', 2026), null);
  assert.equal(birthdayProblem('6', '1', '2020', 2026), 'Check the year, or leave it empty.');
});
