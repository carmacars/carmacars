import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardWords, faceAnswer, outcomeWords, resultLines, type Results } from './model.ts';

const R: Results = { name: 'match', number: 'mismatch', expiry: 'not_checked', face: 'unclear', card_last4: 'match', card_name: 'mismatch' };

test('a face is "different" only when the model is sure, and anything doubtful is unsure', () => {
  assert.equal(faceAnswer({ same_person: 'same', confidence: 85 }), 'same');
  assert.equal(faceAnswer({ same_person: 'Different', confidence: 92 }), 'different');
  assert.equal(faceAnswer({ same_person: 'different', confidence: 70 }), 'unsure');
  assert.equal(faceAnswer({ same_person: 'same', confidence: 40 }), 'unsure');
  assert.equal(faceAnswer({ same_person: 'different' }), 'unsure');
  assert.equal(faceAnswer('I cannot compare faces'), 'unsure');
  assert.equal(faceAnswer(null), 'unsure');
});

test('staff see the card lines; a renter sees only what their photos were compared on', () => {
  assert.deepEqual(resultLines(R, true).map((l) => `${l.label}: ${l.word}`), ['Name: Matches', 'Licence number: Does not match', 'Expiry: Not checked', 'Face: Could not tell',
    'Card, last 4 digits: Matches', 'Name on the card: Does not match']);
  assert.deepEqual(resultLines(R, false).map((l) => l.key), ['name', 'number', 'expiry', 'face']);
});

test('the words never tell anyone to stop: the check does not block the pickup', () => {
  for (const o of ['match', 'mismatch', 'unclear'] as const) for (const staff of [true, false]) assert.doesNotMatch(outcomeWords(o, staff), /stop|cannot|blocked/i);
  assert.match(outcomeWords('mismatch', true), /Fleet and Admin have been told/);
  assert.doesNotMatch(outcomeWords('mismatch', false), /match|wrong/i);
});

test('the card on file in words, never more than its last four digits', () => {
  assert.equal(cardWords({ brand: 'visa', last4: '4242', name: 'Rita Example' }), 'Visa ending in 4242, in the name of Rita Example');
  assert.equal(cardWords({ brand: null, last4: '0005', name: null }), 'Card ending in 0005');
  assert.equal(cardWords(null), 'No card on file for this booking');
});
