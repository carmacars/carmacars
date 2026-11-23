import { test } from 'node:test';
import assert from 'node:assert/strict';
import { amountProblem, applicable, cardState, emailOk, giftLine, ledgerText, normCode, parseDollars, sendDateProblem, type BookingGiftState } from './model.ts';

const money = (c: number) => `$${(c / 100).toFixed(2)}`;

test('a code as typed reaches its stored form; anything else is refused', () => {
  assert.equal(normCode('ccgc 7kq4 xm2p q7xm'), 'CCGC-7KQ4-XM2P-Q7XM');
  assert.equal(normCode('7KQ4-XM2P-Q7XM'), 'CCGC-7KQ4-XM2P-Q7XM');
  assert.equal(normCode(' CCGC-7KQ4-XM2P-Q7XM '), 'CCGC-7KQ4-XM2P-Q7XM');
  assert.equal(normCode('CCGC-7KQ4-XM2P'), null);
  assert.equal(normCode('CCGC-0KQ4-XM2P-Q7XM'), null, 'the digit 0 is never in a code');
  assert.equal(normCode(''), null);
});

test('amounts: whole dollars within the limits, typed the way people type them', () => {
  assert.equal(parseDollars('$1,200'), 120000);
  assert.equal(parseDollars('150.00'), 15000);
  assert.equal(parseDollars('abc'), null);
  assert.equal(amountProblem(5000, 2500, 200000), null);
  assert.equal(amountProblem(5050, 2500, 200000), 'Use whole dollars.');
  assert.equal(amountProblem(1000, 2500, 200000), 'Choose an amount from $25 to $2,000.');
  assert.equal(amountProblem(null, 2500, 200000), 'Choose or type an amount from $25 to $2,000.');
});

test('the send date: empty is now, today or later, within a year', () => {
  assert.equal(sendDateProblem('', '2026-11-23'), null);
  assert.equal(sendDateProblem('2026-11-23', '2026-11-23'), null);
  assert.equal(sendDateProblem('2026-12-25', '2026-11-23'), null);
  assert.equal(sendDateProblem('2026-11-22', '2026-11-23'), 'Pick today or a later date.');
  assert.equal(sendDateProblem('2027-11-24', '2026-11-23'), 'Pick a date within a year.');
  assert.ok(emailOk('jo@example.test') && !emailOk('jo@'));
});

const st = (o: Partial<BookingGiftState>): BookingGiftState => ({ due_cents: 35595, applied_cents: 0, card_due_cents: 35595, has_saved_card: false, min_card_cents: 100,
  room_cents: 35495, blocked: null, deposit_cents: 30000, applications: [], cards: [{ id: 'g', code_last4: 'Q7XM', kind_label: 'Gift card', balance_cents: 15000, rental_text: null }], ...o });

test('Sign and pay: the balance before the card, never more than what is left, a part leaves the rest by card', () => {
  assert.equal(applicable(st({}), 15000), 15000);
  assert.equal(applicable(st({ room_cents: 9000 }), 15000), 9000);
  assert.equal(applicable(st({ room_cents: 0 }), 15000), 0);
  assert.equal(giftLine(st({}), money), 'Your gift card balance is used before your card.');
  assert.equal(giftLine(st({ applied_cents: 15000, card_due_cents: 20595 }), money), '$150.00 from your gift cards. $205.95 is left to pay by card.');
  assert.equal(giftLine(st({ applied_cents: 35595, card_due_cents: 0 }), money), 'Your gift cards pay all of the $355.95. The deposit is still held on your card at pickup.');
});

test('the balance history and the state of a card in words', () => {
  assert.deepEqual(ledgerText({ kind: 'redeem', amount_cents: -15000, balance_after_cents: 0, at: '', booking_number: 'CC-1' }, money), { label: 'Used on booking CC-1', amount: '−$150.00' });
  assert.deepEqual(ledgerText({ kind: 'refund', amount_cents: 5000, balance_after_cents: 5000, at: '', booking_number: 'CC-1' }, money), { label: 'Refund of booking CC-1', amount: '+$50.00' });
  assert.equal(ledgerText({ kind: 'issue', amount_cents: 5000, balance_after_cents: 5000, at: '' }, money).label, 'Issued');
  const now = new Date('2026-11-23T12:00:00Z');
  assert.equal(cardState({ status: 'active', balance_cents: 100, expires_at: null, sent_at: null, send_on: '2026-12-25' }, now), 'Scheduled');
  assert.equal(cardState({ status: 'active', balance_cents: 0, expires_at: null, sent_at: 'x', send_on: null }, now), 'Used up');
  assert.equal(cardState({ status: 'active', balance_cents: 100, expires_at: '2026-11-01T00:00:00Z', sent_at: 'x', send_on: null }, now), 'Ended');
  assert.equal(cardState({ status: 'voided', balance_cents: 0, expires_at: null, sent_at: 'x', send_on: null }, now), 'Voided');
});
