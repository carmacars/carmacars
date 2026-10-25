// Unit tests for the assistant's "My queue" lanes (lanes.ts, October 25, 2026): each task lands in its function's lane,
// the lanes come most urgent first (late or past the first reply target), and empty lanes keep their usual order.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildLanes, laneOf, sortTasks, waitWords } from './lanes.ts';
import type { Task } from './tasks.ts';

const NOW = Date.parse('2026-10-25T14:00:00Z');
const ago = (min: number) => new Date(NOW - min * 60_000).toISOString();
const task = (id: string, type: string, min: number, extra: Partial<Task> = {}): Task => ({ id, task_type: type, title: id, queue: 'cs', priority: 'normal', status: 'open', due_at: null, created_at: ago(min), ...extra });

test('each task lands in its function\'s lane, or Other tasks', () => {
  assert.equal(laneOf('cs', 'booking_request'), 'requests');
  assert.equal(laneOf('cs', 'renter_message'), 'messages');
  assert.equal(laneOf('cs', 'phone_missed_call'), 'phone');
  assert.equal(laneOf('finance', 'release_deposit'), 'deposits');
  assert.equal(laneOf('finance', 'refund_cancellation'), 'refunds');
  assert.equal(laneOf('fleet', 'late_return'), 'handovers');
  assert.equal(laneOf('fleet', 'booking_request'), 'other');
});

test('a message past the 5-minute target leads a request that came in a minute ago', () => {
  const lanes = buildLanes('cs', [task('r', 'booking_request', 1), task('m', 'renter_message', 7)], NOW, 5);
  assert.deepEqual(lanes.slice(0, 2).map((l) => [l.key, l.count, l.heat]), [['messages', 1, 2], ['requests', 1, 1]]);
  assert.equal(lanes[0]!.waited, 7);
  assert.equal(lanes[0]!.first?.id, 'm');
});

test('empty lanes follow in their usual order, and Other tasks shows only when it holds something', () => {
  const lanes = buildLanes('finance', [], NOW, 5);
  assert.deepEqual(lanes.map((l) => l.key), ['payments', 'deposits', 'refunds', 'statements', 'tolls']);
  assert.ok(buildLanes('finance', [task('x', 'unknown_type', 3)], NOW, 5).some((l) => l.key === 'other'));
});

test('chats waiting that are not tasks still count, with their own time', () => {
  const [chat] = buildLanes('sales', [], NOW, 5, { chat: { count: 2, since: ago(9) } });
  assert.deepEqual([chat!.key, chat!.count, chat!.waited, chat!.heat], ['chat', 2, 9, 2]);
});

test('escalated and overdue tasks come first, then priority, then the longest waiting', () => {
  const s = sortTasks('cs', [task('a', 'enquiry', 50), task('b', 'enquiry', 2, { priority: 'high' }), task('c', 'enquiry', 1, { escalated: true }), task('d', 'enquiry', 1, { due_at: ago(1) })], NOW, 5);
  assert.deepEqual(s.map((t) => t.id), ['c', 'd', 'b', 'a']);
});

test('waits in words', () => {
  assert.deepEqual([waitWords(0), waitWords(4), waitWords(60), waitWords(72), waitWords(1500)], ['just now', '4 min', '1 h', '1 h 12 min', '1 d 1 h']);
});
