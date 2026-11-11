import { test } from 'node:test';
import assert from 'node:assert/strict';
import { prepareWords, type PrepareProgressData } from './prepare.ts';

const d = (x: Partial<PrepareProgressData> = {}): PrepareProgressData => ({ booking_id: 'b', booking_number: 'CC-1', status: 'confirmed', pickup_at: '2026-11-10T15:00:00Z',
  items: [], total: 2, ticked: 1, job: { id: 'j', kind: 'delivery', status: 'in_progress', scheduled_at: '2026-11-10T14:00:00Z', started_at: null, completed_at: null, who: 'Sam Field' }, ...x });

test('the office sees the count, the job and who has it', () => {
  assert.deepEqual(prepareWords(d()), { count: '1 of 2 in the car', done: false, job: 'Delivery under way, Sam Field.' });
});
test('nothing to prepare, no job yet', () => {
  assert.deepEqual(prepareWords(d({ total: 0, ticked: 0, job: null })), { count: 'Nothing to prepare', done: true, job: 'No pickup or delivery job yet.' });
});
