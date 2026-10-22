import { test } from 'node:test';
import assert from 'node:assert/strict';
import { groupPrompts } from './group.ts';
import type { Prompt } from './types.ts';

const car = (i: number): Prompt => ({ key: `photos:v${i}`, kind: 'photos', priority: 3, title: `Add real photos of 2025 Mercedes-Benz C-Class C43 AMG car number ${i} with a long name`, why: 'It shows sample photos.', since: null, vehicle_id: `v${i}` });
const task = (i: number): Prompt => ({ key: `task:t${i}`, kind: 'task', task_type: 'maintenance_backfill', priority: 2, title: `Record the last service: 2021 Kia Forte ${i}`, why: null, since: null, vehicle_id: `v${i}` });

test('72 cars to photograph are one short line with the list inside', () => {
  const lines = groupPrompts(Array.from({ length: 72 }, (_, i) => car(i)));
  assert.equal(lines.length, 1);
  const l = lines[0]!;
  assert.ok(!('one' in l));
  assert.equal(!('one' in l) && l.title, 'Add real photos (72 cars)');
  assert.equal(!('one' in l) && l.items.length, 72);
});

test('tasks of one type: the words their titles share', () => {
  const lines = groupPrompts([task(1), task(2), task(3)]);
  assert.equal(lines.length, 1);
  assert.equal(!('one' in lines[0]!) && lines[0]!.title, 'Record the last service (3 cars)');
});

test('fewer than three stay lines of their own; a decision about one person always does; the order is kept', () => {
  const chats: Prompt[] = [1, 2, 3].map((i) => ({ key: `chat:c${i}`, kind: 'chat', priority: 1, title: `Visitor ${i} asked for a person`, why: null, since: null }));
  const lines = groupPrompts([chats[0]!, car(1), chats[1]!, car(2), chats[2]!]);
  assert.deepEqual(lines.map((l) => l.key), ['chat:c1', 'photos:v1', 'chat:c2', 'photos:v2', 'chat:c3']);
});

test('a group takes the place and the priority of its most urgent line', () => {
  const lines = groupPrompts([{ ...task(1), priority: 1 }, car(1), task(2), task(3)]);
  assert.deepEqual(lines.map((l) => l.key), ['group:task:maintenance_backfill', 'photos:v1']);
  assert.equal(!('one' in lines[0]!) && lines[0]!.priority, 1);
});
