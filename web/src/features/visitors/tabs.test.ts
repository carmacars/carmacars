import { test } from 'node:test';
import assert from 'node:assert/strict';
import { VISITOR_TABS, addQuery, chatMovedTo, liveMovedTo, viewHref, viewOf } from './tabs.ts';

// r27 consolidation: Live now, Chat and History on one Visitors page; the old Live chat and Live visitors addresses redirect
test('the tab shown: ?view=, else Live now', () => {
  assert.equal(viewOf('chat'), 'chat');
  assert.equal(viewOf('history'), 'history');
  assert.equal(viewOf(undefined), 'live');
  assert.equal(viewOf('phone'), 'live');
  assert.equal(viewOf(['chat']), 'chat');
});

test('each tab\'s address, for Admin and staff', () => {
  assert.equal(viewHref('admin', 'live'), '/admin/visitors');
  assert.equal(viewHref('admin', 'chat'), '/admin/visitors?view=chat');
  assert.equal(viewHref('staff', 'history'), '/staff/visitors?view=history');
  assert.deepEqual(VISITOR_TABS.admin.map((t) => t.label), ['Live now', 'Chat', 'History', 'Texts and calls']);
  assert.equal(VISITOR_TABS.staff[3]!.href, '/staff/visitors?view=chat&inbox=phone');
});

test('old Live chat addresses keep their query', () => {
  assert.equal(chatMovedTo('admin', {}), '/admin/visitors?view=chat');
  assert.equal(chatMovedTo('admin', { id: 'abc' }), '/admin/visitors?view=chat&id=abc');
  assert.equal(chatMovedTo('staff', { view: 'phone', id: 'x1' }), '/staff/visitors?view=chat&inbox=phone&id=x1');
  assert.equal(chatMovedTo('staff', { view: 'other', a: ['1', '2'] }), '/staff/visitors?view=chat&a=1&a=2');
});

test('the old staff Live visitors address goes to Live now with its query', () => {
  assert.equal(liveMovedTo({}), '/staff/visitors');
  assert.equal(liveMovedTo({ q: 'x', view: 'old' }), '/staff/visitors?q=x');
});

test('a query added to an address with or without one', () => {
  assert.equal(addQuery('/admin/visitors?view=chat', { id: '1' }), '/admin/visitors?view=chat&id=1');
  assert.equal(addQuery('/admin/chat', { inbox: 'phone' }), '/admin/chat?inbox=phone');
  assert.equal(addQuery('/a', {}), '/a');
});
