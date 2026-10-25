import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ledgerCsv, ledgerFilters, refundMaths, type LedgerRow, type RefundItem } from './ledger.ts';

test('the filters default to today and keep only known methods', () => {
  assert.deepEqual(ledgerFilters({}, '2026-10-24'), { from: '2026-10-24', to: '2026-10-24', methods: [] });
  assert.deepEqual(ledgerFilters({ from: '2026-10-01', to: '2026-10-07', method: ['cash', 'e_transfer,card', 'bitcoin'] }, '2026-10-24'),
    { from: '2026-10-01', to: '2026-10-07', methods: ['card', 'e_transfer', 'cash'] });
  assert.deepEqual(ledgerFilters({ from: '2026-10-09', to: '2026-10-02' }, '2026-10-24'), { from: '2026-10-02', to: '2026-10-09', methods: [] });
  assert.deepEqual(ledgerFilters({ from: 'yesterday' }, '2026-10-24').from, '2026-10-24');
});

const row = (p: Partial<LedgerRow>): LedgerRow => ({ id: 'x', day: '2026-10-24', at: '2026-10-24T16:05:00Z', channel: 'cash', channel_label: 'Cash', kind: 'charge', direction: 'in',
  what: 'Payment: Deposit', how: 'Cash', reference: null, amount_cents: 100000, status: 'Received', booking_number: 'CC-10001', who: 'Riley Renter', recorded_by: 'Finn Field', ...p });

test('the CSV: a line per payment, refunds negative, holds marked, no formula injection', () => {
  const csv = ledgerCsv([row({}), row({ kind: 'refund', direction: 'out', amount_cents: 23939, what: 'Refund: Rental', channel: 'card', channel_label: 'Card', how: 'Card Visa ending 4242', status: 'Refunded' }),
    row({ kind: 'hold', direction: 'held', what: 'Card hold (not money in yet): Deposit', who: '=HYPERLINK("x")' })]);
  const lines = csv.trim().split('\r\n');
  assert.equal(lines[0], 'Date,Time,Method,What,How,Reference,Booking,From or to,Amount,Status,Recorded by');
  assert.equal(lines[1], '2026-10-24,12:05,Cash,Payment: Deposit,Cash,,CC-10001,Riley Renter,1000.00,Received,Finn Field');
  assert.match(lines[2]!, /,-239\.39,Refunded,/);
  assert.match(lines[3]!, /"'=HYPERLINK\(""x""\)"/);
  assert.match(lines[3]!, /Held \(not money in\)/);
});

test('the refund maths reads as one sentence', () => {
  const base: Omit<RefundItem, 'maths'> = { id: 'r', booking_number: 'CC-1', who: null, reason: 'cancellation', reason_label: 'Cancelled by the renter', amount_cents: 23939, refund_bps: 9500,
    status: 'pending_approval', created_at: '', due_by: null, note: null, requested_by: null, method: 'Card', can_approve: true, can_decline: true, can_issue: false };
  assert.equal(refundMaths({ ...base, maths: { paid_cents: 25199, tier: 'more_than_7_days', refund_bps: 9500, refund_cents: 23939, kept_cents: 1260, matches: true } }),
    'Paid $251.99 · more than 7 days: 95% back = $239.39, kept $12.60');
  assert.equal(refundMaths({ ...base, maths: { paid_cents: 10000, refund_bps: 5000, refund_cents: 5000 } }), 'Paid $100.00 · 50% back = $50.00');
});
