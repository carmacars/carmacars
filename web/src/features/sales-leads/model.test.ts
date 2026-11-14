// The Sales lead list (0950): the claim line, the lead's state, contact links, the list query and the dashboard words.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { age, BEFORE_TODAY_FILTER, bulkFilter, bulkWords, claimPaceWords, claimWords, contactLinks, contextLine, holdWords, HISTORY_LABEL, listQuery, minutes, owedWords, pct, phoneMasked, phoneOwner, signalGroup, stateOf, type LeadClaim, type LeadHold } from './model.ts';
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

const hold = (mine: boolean, locked: boolean, min = 10): LeadHold => ({ by: 'u', name: 'Sam Cs', first_name: 'Sam', role: 'cs', role_label: 'Customer service', since: '2026-11-08T14:55:00Z', until: new Date(now + min * 60_000).toISOString(), mine, locked });

test('2320: the hold line names the first name, the role and the time; it locks Sales, not the holder', () => {
  assert.deepEqual(holdWords(hold(false, true), now), { text: 'Being handled by Sam (Customer service) until 10:10 am', mine: false, locked: true });
  assert.deepEqual(holdWords({ ...hold(false, true), role: 'fleet', role_label: 'Fleet' }, now).text, 'Being handled by Sam (Fleet) until 10:10 am');
  const m = holdWords(hold(true, false), now);
  assert.equal(m.mine, true); assert.equal(m.locked, false); assert.match(m.text ?? '', /^You are handling this lead until 10:10 am/);
  assert.equal(holdWords(hold(false, false), now).locked, false);   // other customer service staff and Admins may still work it
});

test('2320: an ended or missing hold is no hold; the log words exist', () => {
  assert.deepEqual(holdWords(hold(false, true, -1), now), { text: null, mine: false, locked: false });
  assert.deepEqual(holdWords(null, now), { text: null, mine: false, locked: false });
  assert.deepEqual(holdWords(undefined, now), { text: null, mine: false, locked: false });
  for (const a of ['hold', 'hold_extend', 'hold_end']) assert.ok(HISTORY_LABEL[a], a);
});

// ---------------------------------------------------------------- 2411: the person behind the lead, bulk assignment
test('2411: the person in one line: account, bookings, licence verified (never a number), leads', () => {
  const account = { renter: true, has_sign_in: true, email_confirmed: true, identity_status: 'verified', licence_verified: true, blocked: false, since: null };
  assert.equal(contextLine({ account, counts: { bookings: 2, leads: 1 } }), 'Has an account · 2 bookings · licence verified · 1 lead');
  assert.equal(contextLine({ account: { ...account, has_sign_in: false, licence_verified: false, blocked: true }, counts: { bookings: 1, leads: 3 } }), 'Known renter · 1 booking · licence not verified · blocked · 3 leads');
  assert.equal(contextLine({ account: { ...account, renter: false, has_sign_in: false }, counts: { bookings: 0, leads: 1 } }), 'Not a renter yet · 0 bookings · 1 lead');
});

test('2411: money owed in words, or nothing', () => {
  const fmt = (c: number) => `$${(c / 100).toFixed(2)}`;
  assert.equal(owedWords(null, fmt), null);
  assert.equal(owedWords({ owed_cents: 0, rental_cents: 0, charges_cents: 0, overdue: false }, fmt), null);
  assert.equal(owedWords({ owed_cents: 15000, rental_cents: 10000, charges_cents: 5000, overdue: true }, fmt), '$150.00 owed ($100.00 rental, $50.00 charges after a rental), overdue');
});

test('2411: signals fall in groups (talk, site, money, lead); an unknown kind is a site signal', () => {
  for (const t of ['call', 'text', 'whatsapp', 'chat', 'email']) assert.equal(signalGroup(t), 'talk', t);
  for (const t of ['visit', 'car_view', 'quote_seen', 'offer_viewed', 'pay_viewed', 'email_link_opened']) assert.equal(signalGroup(t), 'site', t);
  for (const t of ['booking', 'rented', 'cancelled', 'review']) assert.equal(signalGroup(t), 'money', t);
  assert.equal(signalGroup('lead'), 'lead'); assert.equal(signalGroup('something_new'), 'site');
});

test('2411: the bulk filter is the list filter without the page, sort or Mine; the one press is unassigned and before today', () => {
  assert.deepEqual(bulkFilter({ status: 'unclaimed', source: 'Live chat', age: '30', assigned: 'none', q: 'suv', sort: 'oldest', page: '3', mine: '1' }),
    { status: 'unclaimed', source: 'Live chat', age: 30, assigned: 'none', q: 'suv' });
  assert.deepEqual(bulkFilter({ type: 'renter' }, 'owner'), { type: 'owner' });
  assert.deepEqual({ ...BEFORE_TODAY_FILTER }, { before_today: true, assigned: 'none', status: 'unclaimed' });
});

test('2411: bulk results in words: preview, assigned, already assigned, left for the next press, the pool', () => {
  assert.equal(bulkWords({ preview: true, matched: 0, cap: 500 }), 'No open lead matches.');
  assert.equal(bulkWords({ preview: true, matched: 3, cap: 500 }), '3 leads match.');
  assert.equal(bulkWords({ preview: true, matched: 620, cap: 500 }), '620 leads match. 500 go each time you press; press again for the rest.');
  assert.equal(bulkWords({ matched: 620, changed: 499, unchanged: 1, left: 120, cap: 500, to_name: 'Val Sales' }), '499 leads assigned to Val Sales. 1 lead already was. 120 leads left: press again.');
  assert.equal(bulkWords({ matched: 1, changed: 1, cap: 500, pool: true }), '1 lead back in the pool.');
  assert.equal(HISTORY_LABEL.assign, 'Assigned by an Admin to');
});

test('2411: the lead page and the cards carry the person; the database never sends a licence number', () => {
  const pages = readFileSync(join(import.meta.dirname, 'pages.tsx'), 'utf8');
  assert.match(pages, /'lead_context'/);
  assert.match(readFileSync(join(import.meta.dirname, 'LeadList.tsx'), 'utf8'), /<RenterToggle /);
  const sql = readFileSync(join(import.meta.dirname, '../../../../supabase/migrations/2411_r40_leads.sql'), 'utf8');
  const ctx = sql.slice(sql.indexOf('create or replace function app.lead_context('), sql.indexOf('create or replace function app.lead_context_open('));
  for (const banned of ['licence_number', 'date_of_birth', 'card_last4', 'payment_methods', 'sin']) assert.ok(!new RegExp(`\\b${banned}\\b`).test(ctx), banned);
});

// 2870: an Admin shows a lead's phone to its salesperson (the claim holder when nobody is assigned); masked means the dots
test('lead phone: masked, and who Show the phone goes to', () => {
  assert.equal(phoneMasked('(905) \u2022\u2022\u2022-\u2022\u202271'), true);
  assert.equal(phoneMasked('905-555-0171'), false);
  assert.equal(phoneMasked(null), false);
  const claim = { by: 'c1', name: 'Cora', since: '', until: '', cap: '', mine: false } as LeadClaim;
  assert.deepEqual(phoneOwner({ assigned_to: 'a1', assigned_name: 'Ana', claim }), { id: 'a1', name: 'Ana' });
  assert.deepEqual(phoneOwner({ assigned_to: null, assigned_name: null, claim }), { id: 'c1', name: 'Cora' });
  assert.equal(phoneOwner({ assigned_to: null, assigned_name: null, claim: null }), null);
  // the lead page, the cards and the To do of the ask all carry it
  assert.match(readFileSync(join(import.meta.dirname, 'LeadActions.tsx'), 'utf8'), /<LeadPhoneAccess /);
  assert.match(readFileSync(join(import.meta.dirname, 'LeadList.tsx'), 'utf8'), /<PhoneValue /);
  assert.match(readFileSync(join(import.meta.dirname, '../admin/todo/registry.tsx'), 'utf8'), /lead_phone_ask:/);
});
