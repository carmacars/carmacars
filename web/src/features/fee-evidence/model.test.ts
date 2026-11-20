import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CLEAN_CHOICES, CLEAN_SHOTS, cleanMissing, evidenceLabel } from './model.ts';

test('a return that is not clean needs 3 guided photos and a description', () => {
  assert.equal(cleanMissing('clean', 0, ''), null);
  assert.equal(cleanMissing('smoking', 0, ''), '3 more evidence photos');
  assert.equal(cleanMissing('smoking', 2, ''), '1 more evidence photo');
  assert.equal(cleanMissing('smoking', 3, 'smells'), 'A written description');
  assert.equal(cleanMissing('heavy', 4, 'Mud on every mat and both rear seats'), null);
});

test('the Checklist saves the values the database keeps', () => {
  const values = CLEAN_CHOICES.map(([v]) => v);
  assert.deepEqual(values, ['clean', 'cleaning', 'heavy', 'pet', 'smoking']);
  assert.ok(CLEAN_SHOTS.every((s) => /^clean_[a-z]+$/.test(s.shot)));
  assert.ok(['clean_ash', 'clean_seats', 'clean_headliner', 'clean_cupholders', 'clean_floor'].every((s) => CLEAN_SHOTS.some((x) => x.shot === s)));
});

test('every kind of evidence has words', () => {
  assert.equal(evidenceLabel('final_notice'), 'the final late notice with its deadline passed');
  assert.equal(evidenceLabel('something_new'), 'something new');
});
