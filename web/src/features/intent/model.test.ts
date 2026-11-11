import { test } from 'node:test';
import assert from 'node:assert/strict';
import { intentLine, intentPhrases, parseAiSignals } from './model.ts';

test('intent words: the signals in short phrases, the label and score', () => {
  assert.deepEqual(intentPhrases({ budget: { amount_cents: 60000, per: 'week' }, car_class: 'suv', duration_days: 14, dates: 'nov 20', urgency: 'high', delivery: true, coverage: 'own_insurance' }),
    ['$600/week', 'SUV', '2 weeks', 'nov 20', 'needs it now', 'delivery', 'own insurance']);
  assert.equal(intentLine({ score: 78, label: 'hot', signals: { duration_days: 30 } }), 'Hot 78: 1 month');
  assert.equal(intentLine({ score: 0, label: 'unknown', signals: {} }), 'No intent signals yet');
});

test('the AI reply keeps only known keys and sane values', () => {
  assert.deepEqual(parseAiSignals({ budget: { amount: 600, per: 'week' }, car_class: 'SUV', duration_days: 14, urgency: 'soon', delivery: 'yes', coverage: 'card', extra: 1 }),
    { budget: { amount_cents: 60000, per: 'week' }, car_class: 'suv', duration_days: 14, coverage: 'card' });
  assert.equal(parseAiSignals('nope'), null);
  assert.deepEqual(parseAiSignals({ car_class: 'spaceship', duration_days: 900 }), {});
});
