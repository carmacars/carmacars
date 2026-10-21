// Unit tests for where a task opens (tasks.ts, migration 0078): an assistant's task opens its working screen (a chat
// waiting for a person opens that chat, a Protection Plan request the identity and coverage review), and the same task
// on the Admin's side opens the Admin screen where its work is done, never the task sheet when a record is known.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { adminTaskHref, taskHref, type Task } from './tasks.ts';

const base: Task = { id: 't1', task_type: 'x', title: 'T', queue: 'cs', priority: 'normal', status: 'open', due_at: null, created_at: '2026-10-21T12:00:00Z' };
const chat = '7b0d9f0e-1111-4222-8333-944445555666';

test('an assistant: a chat waiting for a person opens that chat', () => {
  assert.equal(taskHref({ ...base, task_type: 'live_chat_waiting', related_table: 'chat_conversations', related_id: chat }), `/va/chat?id=${chat}`);
  assert.equal(taskHref({ ...base, task_type: 'live_chat_waiting' }), '/va/chat');
});

test('an assistant: coverage and Protection Plan tasks open the identity and coverage review', () => {
  assert.equal(taskHref({ ...base, task_type: 'protection_plan_request', booking_number: 'CC-1042' }), '/va/verify/CC-1042?task=t1');
  assert.equal(taskHref({ ...base, task_type: 'verify_renter', booking_number: 'CC-1042' }), '/va/verify/CC-1042?task=t1');
});

test('an assistant: the other kinds keep their screens', () => {
  assert.equal(taskHref({ ...base, task_type: 'collect_upfront' }), '/va/money');
  assert.equal(taskHref({ ...base, task_type: 'opening_checks' }), '/va/checks?kind=opening');
  assert.equal(taskHref({ ...base, task_type: 'unknown_kind' }), '/va/tasks/t1');
});

test('the Admin: each task opens where its work is done', () => {
  const t = { task_type: '', booking_number: null, vehicle_id: null, related_table: null, related_id: null };
  assert.equal(adminTaskHref({ ...t, task_type: 'live_chat_waiting', related_table: 'chat_conversations', related_id: chat }), `/admin/chat?id=${chat}`);
  assert.equal(adminTaskHref({ ...t, task_type: 'verify_renter', booking_number: 'CC-1042' }), '/admin/bookings/CC-1042?tab=documents');
  assert.equal(adminTaskHref({ ...t, task_type: 'booking_request', booking_number: 'CC-1042' }), '/admin/bookings/CC-1042?tab=review');
  assert.equal(adminTaskHref({ ...t, task_type: 'collect_upfront', invoice_number: 'INV-1052' }), '/admin/invoices/INV-1052');
  assert.equal(adminTaskHref({ ...t, task_type: 'collect_upfront', owner_id: 'o1' }), '/admin/owners/o1?tab=invoices');
  assert.equal(adminTaskHref({ ...t, task_type: 'owner_intake', owner_id: 'o1' }), '/admin/owners/o1');
  assert.equal(adminTaskHref({ ...t, task_type: 'first_last_decide', owner_id: 'o1' }), '/admin/owners/o1?tab=terms');
  assert.equal(adminTaskHref({ ...t, task_type: 'live_rental_insurance', vehicle_id: 'v1' }), '/admin/vehicles/v1?tab=listing');
  assert.equal(adminTaskHref({ ...t, task_type: 'fleet_minimum' }), '/admin/overview');
});

test('the Admin: an unknown kind falls back to its record, then to Tasks', () => {
  const t = { task_type: 'something_new', booking_number: null, vehicle_id: null, related_table: null, related_id: null };
  assert.equal(adminTaskHref({ ...t, booking_number: 'CC-9' }), '/admin/bookings/CC-9');
  assert.equal(adminTaskHref({ ...t, vehicle_id: 'v9' }), '/admin/vehicles/v9');
  assert.equal(adminTaskHref(t), '/admin/tasks');
});
