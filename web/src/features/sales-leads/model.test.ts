// The Sales lead list (0950): the claim line, the lead's state, contact links, the list query and the dashboard words.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { age, claimPaceWords, claimWords, contactLinks, listQuery, minutes, pct, stateOf, type LeadClaim } from './model.ts';
import { taskHref, adminTaskHref, type Task } from '../va/tasks.ts';

const now = Date.parse('2026-11-08T15:00:00Z');
const claim = (mine: boolean, min = 10): LeadClaim => ({ by: 'u', name: 'Val Sales', since: '2026-11-08T14:55:00Z', until: new Date(now + min * 60_000).toISOString(), cap: new Date(now + 55 * 60_000).toISOString(), mine });

test('claim line: mine says until when and that contacts add time; another person\'s locks the buttons', () => {
  const m = claimWords(claim(true), now);
  assert.equal(m.mine, true); assert.equal(m.locked, false);
  assert.match(m.text ?? '', /^Yours until 10:10 am \(10 min\)\. Each call, text, email or note adds time, up to 10:55 am\.$/);
  const o = claimWords(claim(false), now);
  assert.deepEqual([o.mine, o.locked, o.text], [false, true, 'Val Sales is on it until 10:10 am']);
});

test('claim line: a claim that ran out is no claim', () => {
  assert.deepEqual(claimWords(claim(false, -1), now), { text: null, mine: false, locked: false });
  assert.deepEqual(claimWords(null, now), { text: null, mine: false, locked: false });
});

test('state: won and lost first, then handled, the outcome, new or open', () => {
  assert.equal(stateOf({ outcome: 'won', handled_at: 'x', status: 'converted', new: false }), 'Won');
  assert.equal(stateOf({ outcome: null, handled_at: null, status: 'closed', new: false }), 'Lost');
  assert.equal(stateOf({ outcome: null, handled_at: 'x', status: 'contacted', new: false }), 'Handled');
  assert.equal(stateOf({ outcome: 'call_booked', handled_at: null, status: 'contacted', new: false }), 'Call booked');
  assert.equal(stateOf({ outcome: null, handled_at: null, status: 'new', new: true }), 'New');
});

test('contact links: tel, sms and mailto, or none', () => {
  assert.deepEqual(contactLinks({ phone: '+1 (416) 555-0142', email: 'a@example.test' }), { call: 'tel:+14165550142', text: 'sms:+14165550142', email: 'mailto:a@example.test' });
  assert.deepEqual(contactLinks({ phone: null, email: null }), { call: null, text: null, email: null });
});

test('list query: only known values reach the database; the fixed type wins', () => {
  assert.deepEqual(listQuery({ type: 'owner', status: 'claimed', age: '7', mine: '1', q: 'sam', sort: 'oldest', page: '2' }),
    { type: 'owner', status: 'claimed', age: 7, mine: true, q: 'sam', sort: 'oldest', offset: 50, limit: 50 });
  assert.deepEqual(listQuery({ type: 'nope', status: 'drop table', age: 'x', assigned: 'nobody', sort: 'random' }), { limit: 50 });
  assert.equal(listQuery({ type: 'renter' }, 'owner').type, 'owner');
});

test('words: age, percentages and minutes', () => {
  assert.equal(age(new Date(now - 30_000).toISOString(), now), 'just now');
  assert.equal(age(new Date(now - 12 * 60_000).toISOString(), now), '12 min ago');
  assert.equal(age(new Date(now - 3 * 3_600_000).toISOString(), now), '3 h ago');
  assert.equal(age(new Date(now - 3 * 86_400_000).toISOString(), now), '3 days ago');
  assert.equal(pct(33, 3), '33%'); assert.equal(pct(0, 0), '-');
  assert.equal(minutes(null), '-'); assert.equal(minutes(4), '4 min'); assert.equal(minutes(75), '1 h 15 min');
});

test('tasks about a lead open that lead (the new owner program enquiry and the others)', () => {
  const t = { id: 't', task_type: 'owner_lead', title: 'New owner program enquiry', queue: 'sales', priority: 'normal', status: 'open', due_at: null, created_at: '2026-11-08T00:00:00Z', related_table: 'leads', related_id: 'abc' } as Task;
  assert.equal(taskHref(t), '/staff/sales-leads/abc');
  assert.equal(adminTaskHref(t), '/admin/sales-leads/abc');
  assert.equal(taskHref({ ...t, task_type: 'enquiry' }), '/staff/sales-leads/abc');
});

test('the alerts and pages use the same lead address', () => {
  const sql = readFileSync(join(import.meta.dirname, '../../../../supabase/migrations/0950_r35y_sales_leads.sql'), 'utf8');
  assert.match(sql, /'\/admin\/sales-leads' else '\/staff\/sales-leads'/);
  for (const p of ['admin/sales-leads/[id]/page.tsx', 'staff/sales-leads/[id]/page.tsx', 'staff/owner-leads/page.tsx']) assert.ok(readFileSync(join(import.meta.dirname, '../../app', p), 'utf8').includes('SalesLead'), p);
});

test('1152: the claiming limits in words: held of the most, and the next claim in mm:ss', () => {
  const at = Date.parse('2026-11-09T15:00:00Z');
  assert.equal(claimPaceWords({ held: 1, max: 3, nextAt: '2026-11-09T15:04:05Z', cooldown: 5, paced: true }, at), 'you hold 1 of 3 · next claim in 4:05');
  assert.equal(claimPaceWords({ held: 0, max: 3, nextAt: null, cooldown: 5, paced: true }, at), 'you hold 0 of 3 · one claim every 5 min');
  assert.match(claimPaceWords({ held: 3, max: 3, nextAt: null, cooldown: 5, paced: true }, at), /^you hold 3 of 3 \(the most: close or unclaim one/);
  assert.equal(claimPaceWords({ held: 4, max: 3, nextAt: '2026-11-09T15:04:05Z', cooldown: 5, paced: false }, at), 'you hold 4');
  assert.equal(claimPaceWords({ held: 2, max: 4, nextAt: null, cooldown: 0, paced: true, winsToNext: 1 }, at), 'you hold 2 of 4 · 1 more win for one more');
  assert.equal(claimPaceWords({ held: 2, max: 4, nextAt: null, cooldown: 0, paced: true, winsToNext: 3 }, at), 'you hold 2 of 4 · 3 more wins for one more');
});
