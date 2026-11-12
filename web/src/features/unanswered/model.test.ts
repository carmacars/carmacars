import { test } from 'node:test';
import assert from 'node:assert/strict';
import { waitWords } from './model.ts';

test('1061: waiting time in words', () => {
  assert.equal(waitWords(14), '14 min');
  assert.equal(waitWords(75), '1 h 15 min');
  assert.equal(waitWords(1500), '1 d 1 h');
});

test('calls first (r37): missed calls above texts, the longest wait first in each', async () => {
  const { sortUnanswered } = await import('./model.ts');
  const rows = [{ id: 't-old', kind: 'text', waiting_since: '2026-11-11T10:00:00Z' }, { id: 'c-new', kind: 'missed_call', waiting_since: '2026-11-11T12:00:00Z' },
    { id: 't-new', kind: 'text', waiting_since: '2026-11-11T11:30:00Z' }, { id: 'c-old', kind: 'missed_call', waiting_since: '2026-11-11T11:00:00Z' }];
  assert.deepEqual(sortUnanswered(rows).map((r) => r.id), ['c-old', 'c-new', 't-old', 't-new']);
  assert.deepEqual(rows.map((r) => r.id)[0], 't-old');   // the list given is not changed
});
