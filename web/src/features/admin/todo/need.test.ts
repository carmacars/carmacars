import { test } from 'node:test';
import assert from 'node:assert/strict';
import { needCount, ownLines, teamLine, needSentence } from './need.ts';
import type { Prompt, TodoItem } from './types.ts';

const task = (i: number, extra: Partial<Prompt> = {}): Prompt => ({ key: `task:t${i}`, kind: 'task', task_type: 'capture_follow_up', priority: 2, title: `Unfinished request from Person ${i}: follow up`, why: null, since: null, ...extra });
const item = (key: string, count: number, team?: string): TodoItem => ({ key, count, label: key, button: 'Open', href: '/admin', ...(team ? { team } : {}) });

test('200 follow-ups of unfinished forms are not 200 things: the count line is Sales\', the prompts one line', () => {
  const prompts = Array.from({ length: 200 }, (_, i) => task(i));
  assert.equal(needCount({ items: [item('capture_follow_up', 200)], prompts }), 1);
});

test('a staff queue\'s tasks never count, staffed or not', () => {
  const prompts = Array.from({ length: 40 }, (_, i) => task(i, { task_type: 'check_owner_document', from_queue: true, queue: 'cs' }));
  assert.equal(needCount({ items: [], prompts }), 0);
});

test('a count line is one line whatever its count; covered lines and team lines are not counted', () => {
  const items = [item('maintenance_unknown', 12), item('countersign', 4), item('requests', 3), item('tolls', 9), item('site_alerts', 0)];
  assert.deepEqual(ownLines(items).map((i) => i.key), ['countersign']);
  assert.equal(needCount({ items, prompts: [] }), 1);
});

test('the database\'s figure wins when it gives one', () => {
  assert.equal(needCount({ items: [item('countersign', 4)], prompts: [], need: 7 }), 7);
});

test('the words', () => {
  assert.equal(teamLine({ label: 'Customer service', open: 42, overdue: 3 }), 'Customer service has 42 open, 3 overdue');
  assert.equal(teamLine({ label: 'Fleet', open: 0 }), 'Fleet: nothing open');
  assert.equal(needSentence(1), '1 thing needs you, most urgent first.');
  assert.equal(needSentence(5), '5 things need you, most urgent first.');
});
