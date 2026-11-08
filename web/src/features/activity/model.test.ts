import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ACTIVITY_TYPES, TYPE_LABEL, activityQuery, byDay, hiddenFields, itemAction, itemMeta, logHref, readParams, type ActivityItem } from './model.ts';

// The renter's Activity log (migration 0850, release 35): the query from the URL, the links of the chips, search and
// Older, the action of each item, and that every staff page that shows a renter uses the one log.
const item = (over: Partial<ActivityItem> = {}): ActivityItem => ({ k: 'email:1', type: 'email', at: '2026-11-08T15:00:00Z', title: 'Email from the renter', body: 'Hi', dir: 'in', by: null,
  booking_number: 'CC-1', ref: null, extra: null, ...over });

test('every type has its chip, in the order of the database (app.activity_types)', () => {
  assert.deepEqual([...ACTIVITY_TYPES], ['email', 'text', 'chat', 'call', 'note', 'booking', 'payment', 'document', 'visit']);
  for (const t of ACTIVITY_TYPES) assert.ok(TYPE_LABEL[t]);
  const sql = readFileSync(new URL('../../../../supabase/migrations/0850_r35r_activity_log.sql', import.meta.url), 'utf8');
  assert.match(sql, new RegExp(`array\\[${ACTIVITY_TYPES.map((t) => `'${t}'`).join(', ')}\\]`));
});

test('the query: All by default, an unknown type ignored, the search trimmed, the cursor only with a real date', () => {
  assert.deepEqual(activityQuery({}), { type: null, q: '', before: null, k: null });
  assert.equal(activityQuery({ act: 'nonsense' }).type, null);
  assert.equal(activityQuery({ act: 'call' }).type, 'call');
  assert.equal(activityQuery({ aq: '  toll  ' }).q, 'toll');
  assert.equal(activityQuery({ before: 'not a date', bk: 'x' }).before, null);
  assert.deepEqual(readParams(activityQuery({ act: 'text', aq: 'late', before: '2026-11-08T15:00:00Z', bk: 'text:1' })),
    { types: 'text', q: 'late', before: '2026-11-08T15:00:00Z', before_k: 'text:1' });
  assert.deepEqual(readParams(activityQuery({})), {});
});

test('links: a chip keeps the page and the search, starts from the newest, and lands on the log', () => {
  const sp = { booking: 'CC-1', aq: 'toll', before: '2026-11-08T15:00:00Z', bk: 'call:9' };
  assert.equal(logHref('/admin/renters/r1', sp, { type: 'call' }), '/admin/renters/r1?booking=CC-1&act=call&aq=toll#activity');
  assert.equal(logHref('/admin/renters/r1', sp, { type: null, q: null }), '/admin/renters/r1?booking=CC-1#activity');
  // the booking page's tab wins over an old tab name in the address
  assert.equal(logHref('/staff/bookings/CC-1?tab=activity', { tab: 'messages' }, { type: 'text' }), '/staff/bookings/CC-1?tab=activity&act=text#activity');
  // Older keeps the filter
  assert.equal(logHref('/admin/renters/r1', { act: 'email' }, { before: '2026-11-01T00:00:00Z', k: 'email:3' }), '/admin/renters/r1?act=email&before=2026-11-01T00%3A00%3A00Z&bk=email%3A3#activity');
  assert.deepEqual(hiddenFields('/staff/renters?id=r1', { q: 'maya', aq: 'old', act: 'call', before: 'x' }), [['id', 'r1'], ['q', 'maya'], ['act', 'call']]);
});

test('actions: Reply to an email from the renter, Text and Call back, open the chat or the conversation', () => {
  const o = { emailHref: '#email', chatBase: '/admin/visitors?view=chat', inbox: '/admin/visitors?view=chat' };
  assert.deepEqual(itemAction(item(), o), { kind: 'reply', href: '#email' });
  assert.equal(itemAction(item({ dir: 'out' }), o), null);
  assert.equal(itemAction(item(), { ...o, emailHref: null }), null);
  assert.deepEqual(itemAction(item({ type: 'text' }), o), { kind: 'text' });
  assert.deepEqual(itemAction(item({ type: 'call', dir: 'out', extra: { missed: true } }), o), { kind: 'call' });
  assert.deepEqual(itemAction(item({ type: 'chat', ref: 'c1' }), o), { kind: 'link', label: 'Open the chat', href: '/admin/visitors?view=chat&id=c1' });
  assert.deepEqual(itemAction(item({ type: 'text', dir: 'out', ref: 't1' }), o), { kind: 'link', label: 'Open the conversation', href: '/admin/visitors?view=chat&inbox=phone&id=t1' });
  assert.equal(itemAction(item({ type: 'note' }), o), null);
});

test('the line under a title, and the day headings in Toronto', () => {
  assert.equal(itemMeta(item({ type: 'call', by: 'Riley', extra: { duration: 125, summary_by: 'ai' } })), 'Riley · CC-1 · 2 min · summary by AI');
  assert.equal(itemMeta(item({ booking_number: null })), '');
  const days = byDay([item({ at: '2026-11-08T15:00:00Z' }), item({ k: 'b', at: '2026-11-08T14:00:00Z' }), item({ k: 'c', at: '2026-11-08T03:00:00Z' })]);
  assert.deepEqual(days.map((d) => d.items.length), [2, 1]); // 03:00 UTC is the evening before in Toronto
});

test('every staff page that shows a renter uses the one log, and the old cards are gone', () => {
  const read = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8');
  for (const p of ['../../app/admin/renters/[id]/page.tsx', '../renters-page/RentersPage.tsx', '../booking-page/BookingPage.tsx']) {
    const s = read(p);
    assert.match(s, /<ActivityLog /, p);
    assert.match(s, /'renter_activity'/, p);
    assert.doesNotMatch(s, /PhoneTimeline|VisitorTimeline/, p);
  }
});
