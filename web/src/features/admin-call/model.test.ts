import { test } from 'node:test';
import assert from 'node:assert/strict';
import { callSlides, openDecisions, scheduleWords, type Slide } from './model.ts';

test('the schedule in words: Sunday 7 pm by default', () => {
  assert.equal(scheduleWords({ weekday: 7, time: '19:00', minutes: 60 }), 'Every Sunday at 7:00 pm Toronto time, 60 minutes');
  assert.equal(scheduleWords({ weekday: 1, time: '09:05', minutes: 45 }), 'Every Monday at 9:05 am Toronto time, 45 minutes');
  assert.equal(scheduleWords({ weekday: 3, time: '12:30', minutes: 30 }), 'Every Wednesday at 12:30 pm Toronto time, 30 minutes');
});

const slides: Slide[] = [
  { key: 'shifts', title: 'Shifts', points: [{ label: 'Claims', value: '2' }], items: [
    { key: 'shift:a', kind: 'shift', label: 'Ana', detail: 'Sat 10 am', href: '/admin/field-jobs', approve: 'Approve', deny: 'Take off the shift', decision: 'deny' },
    { key: 'shift:b', kind: 'shift', label: 'Bo', detail: 'Sun 9 am', href: '/admin/field-jobs', approve: 'Approve', deny: 'Take off the shift' }] },
  { key: 'numbers', title: 'Numbers', points: [], lines: ['Leads from google: 4'], note: 'Push the airport page' }
];

test('the decisions still open', () => {
  assert.deepEqual(openDecisions(slides), { open: 1, total: 2 });
});

test('the call deck: lines, items with their decision, the note last', () => {
  const c = callSlides(slides);
  assert.deepEqual(c[0]!.lines, ['Ana: Sat 10 am (Take off the shift)', 'Bo: Sun 9 am']);
  assert.deepEqual(c[1]!.lines, ['Leads from google: 4', 'Push the airport page']);
});
