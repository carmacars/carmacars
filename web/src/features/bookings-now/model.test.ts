import { test } from 'node:test';
import assert from 'node:assert/strict';
import { countdown, depositWords, filterOut, fuel, initial, money, nextPay, phoneHref, planWords, span, when, type Pay, type Rental } from './model.ts';

// noon, November 4 2026, Toronto (17:00 UTC)
const NOW = Date.parse('2026-11-04T17:00:00Z');
const pay = (p: Partial<Pay>): Pay => ({ plan: 'weekly', set: true, state: 'upcoming', owed_cents: 280000, paid_cents: 140000, open_cents: 140000, count: 4, per_cents: 70000, overdue_count: 0,
  next: { seq: 3, due_at: '2026-11-08T17:00:00Z', cents: 70000, instalment_cents: 70000 }, insurer: null, schedule: [], ...p });

test('money: whole dollars without cents', () => {
  assert.equal(money(70000), '$700');
  assert.equal(money(123456), '$1,234.56');
  assert.equal(money(null), '$0');
});

test('span and countdown: days and hours, then hours and minutes', () => {
  assert.equal(span(3 * 86_400_000 + 4 * 3_600_000), '3d 4h');
  assert.equal(span(86_400_000 + 3_600_000), '1d 1h');
  assert.equal(span(3 * 3_600_000 + 5 * 60_000), '3h 05m');
  assert.equal(span(12 * 60_000), '12m');
  assert.deepEqual(countdown('2026-11-04T20:00:00Z', NOW), { text: 'in 3h 00m', late: false });
  assert.deepEqual(countdown('2026-11-04T14:00:00Z', NOW), { text: '3h 00m late', late: true });
});

test('when: Toronto days, today and tomorrow in words', () => {
  assert.equal(when('2026-11-04T19:30:00Z', NOW), 'Today 2:30 pm');
  assert.equal(when('2026-11-05T15:00:00Z', NOW), 'Tomorrow 10 am');
  assert.equal(when('2026-11-03T14:00:00Z', NOW), 'Yesterday 9 am');
  assert.match(when('2026-11-08T17:00:00Z', NOW), /^Sun Nov 8, 12 pm$/);
  // 11:30 pm Toronto is still today though it is tomorrow in UTC
  assert.equal(when('2026-11-05T04:30:00Z', NOW), 'Today 11:30 pm');
});

test('the plan in words', () => {
  assert.equal(planWords(pay({})), '$700 a week');
  assert.equal(planWords(pay({ plan: 'biweekly', per_cents: 140000 })), '$1,400 every 2 weeks');
  assert.equal(planWords(pay({ plan: 'monthly', per_cents: 180000 })), '$1,800 a month');
  assert.equal(planWords(pay({ plan: 'insurer', insurer: { name: 'Example Insurance', claim: 'C-1', share_cents: 50000, paid_cents: 0 } })), 'Insurer billed · Example Insurance');
  assert.equal(planWords(pay({ plan: 'whole', owed_cents: 60000 })), 'Whole rental · $600');
});

test('the next payment: overdue red, soon dark, paid up green, insurer quiet', () => {
  const o = nextPay(pay({ state: 'overdue', overdue_count: 2, next: { seq: 2, due_at: '2026-10-22T17:00:00Z', cents: 140000, instalment_cents: 70000 } }), NOW);
  assert.equal(o.tone, 'red'); assert.equal(o.amount, '$1,400'); assert.equal(o.sub, '2 payments behind'); assert.match(o.label, /^Overdue 13d/);
  const s = nextPay(pay({ state: 'soon', next: { seq: 2, due_at: '2026-11-06T17:00:00Z', cents: 140000, instalment_cents: 140000 }, count: 2 }), NOW);
  assert.equal(s.tone, 'dark'); assert.equal(s.label, 'Fri Nov 6, 12 pm'); assert.equal(s.sub, 'Payment 2 of 2');
  assert.equal(nextPay(pay({ state: 'paid', next: null, paid_cents: 280000 }), NOW).tone, 'ok');
  assert.equal(nextPay(pay({ plan: 'insurer', state: 'none', next: null }), NOW).label, 'Insurer pays');
});

test('phone links: any typing of a North American number', () => {
  assert.equal(phoneHref('647-555-0199', 'tel'), 'tel:+16475550199');
  assert.equal(phoneHref('+1 (647) 555 0199', 'sms'), 'sms:+16475550199');
  assert.equal(phoneHref('555', 'tel'), null);
  assert.equal(phoneHref(null, 'tel'), null);
});

test('fuel, deposit, initial', () => {
  assert.equal(fuel(75), '6/8');
  assert.equal(fuel(null), '');
  assert.deepEqual(depositWords({ required_cents: 100000, waived: false, held_cents: 100000, how: 'card_hold' }), { text: '$1,000 held', ok: true });
  assert.deepEqual(depositWords({ required_cents: 100000, waived: false, held_cents: 0, how: null }), { text: '$1,000 not held', ok: false });
  assert.deepEqual(depositWords({ required_cents: 50000, waived: false, held_cents: 50000, how: 'cash' }), { text: '$500 cash', ok: true });
  assert.equal(initial('2024 Mercedes-Benz C 300'), 'M');
});

test('the Out now filters', () => {
  const r = (due: Rental['due'], state: Pay['state']) => ({ due, pay: pay({ state }) }) as Rental;
  const rows = [r('overdue', 'paid'), r('today', 'upcoming'), r('later', 'soon'), r('later', 'overdue'), r('tomorrow', 'paid')];
  assert.equal(filterOut(rows, 'all').length, 5);
  assert.equal(filterOut(rows, 'late').length, 1);
  assert.equal(filterOut(rows, 'today').length, 2);
  assert.equal(filterOut(rows, 'pay').length, 2);
});
