import { test } from 'node:test';
import assert from 'node:assert/strict';
import { birthdayOfKey, birthdayWords } from './birthday.ts';

test('birthday (4600): words a real day, February 29 included', () => { assert.equal(birthdayWords(3, 14), 'March 14'); assert.equal(birthdayWords(2, 29), 'February 29'); });
test('birthday (4600): refuses a day the month has not', () => { assert.equal(birthdayWords(4, 31), null); assert.equal(birthdayWords(13, 1), null); assert.equal(birthdayWords(null, 3), null); });
test('birthday (4600): reads the staff list key', () => { assert.equal(birthdayOfKey('11-26'), 'November 26'); assert.equal(birthdayOfKey(null), null); assert.equal(birthdayOfKey('x'), null); });
