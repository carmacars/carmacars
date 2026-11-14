// The owner portal's Rental history (r44, 2830): the list's query, its words and its totals line.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { carText, earnedText, historyHref, historyOffset, historyQuery, pageCount, stateLabel, summaryText, torontoWhen, HISTORY_PAGE } from './history.ts';

const CAR = '0f8fad5b-d9cb-469f-a165-70867728950e';

test('the query: a car id, newest first and the page; anything else ignored', () => {
  assert.deepEqual(historyQuery({}), { car: null, newest: false, page: 1 });
  assert.deepEqual(historyQuery({ car: CAR.toUpperCase(), order: 'newest', page: '3' }), { car: CAR, newest: true, page: 3 });
  assert.deepEqual(historyQuery({ car: "x' or 1=1", order: 'oldest', page: '-2' }), { car: null, newest: false, page: 1 });
  assert.equal(historyQuery({ page: 'abc' }).page, 1);
  assert.equal(historyOffset({ car: null, newest: false, page: 3 }), 2 * HISTORY_PAGE);
});

test('the address keeps the tab and the filter, and drops page 1', () => {
  const q = historyQuery({ car: CAR, page: '2' });
  assert.equal(historyHref(q), `/owner/vehicles?tab=bookings&car=${CAR}&page=2#rental-history`);
  assert.equal(historyHref(q, { newest: true, page: 1 }), `/owner/vehicles?tab=bookings&car=${CAR}&order=newest#rental-history`);
  assert.equal(historyHref(q, { car: null, page: 1 }), '/owner/vehicles?tab=bookings#rental-history');
});

test('pages', () => {
  assert.equal(pageCount(0), 1);
  assert.equal(pageCount(HISTORY_PAGE), 1);
  assert.equal(pageCount(HISTORY_PAGE + 1), 2);
  assert.equal(pageCount(512), Math.ceil(512 / HISTORY_PAGE));
});

test('status in plain words', () => {
  assert.equal(stateLabel('upcoming'), 'Upcoming');
  assert.equal(stateLabel('on_rent'), 'On rent');
  assert.equal(stateLabel('completed'), 'Completed');
  assert.equal(stateLabel('cancelled_kept'), 'Cancelled, charge kept');
});

test('pickup and return in Toronto time, whatever the server zone', () => {
  assert.equal(torontoWhen('2026-10-10T14:00:00Z'), 'Oct 10, 2026, 10:00 a.m.');
  assert.equal(torontoWhen('2026-12-01T04:30:00Z'), 'Nov 30, 2026, 11:30 p.m.');
  assert.equal(torontoWhen(null), '');
});

test('earnings as the statements show them', () => {
  assert.equal(earnedText({ earned_cents: null, more_to_come: false }), 'Not yet on a statement');
  assert.equal(earnedText({ earned_cents: 19500, more_to_come: false }), '$195.00');
  assert.equal(earnedText({ earned_cents: 6500, more_to_come: true }), '$65.00, more on a later statement');
  assert.equal(earnedText({ earned_cents: 0, more_to_come: false }), '$0.00');
});

test('the car and the totals line', () => {
  assert.equal(carText({ car: '2023 Mercedes-Benz C 300', plate: 'ABCD 123' }), '2023 Mercedes-Benz C 300 · ABCD 123');
  assert.equal(carText({ car: null, plate: null }), 'Car');
  assert.equal(summaryText({ count: 0, days: 0, earned_cents: 0, not_on_statement: 0 }), 'No rentals yet.');
  assert.equal(summaryText({ count: 1, days: 1, earned_cents: 10000, not_on_statement: 0 }), '1 rental · 1 day · $100.00 on your statements');
  assert.equal(summaryText({ count: 3, days: 9, earned_cents: 45050, not_on_statement: 1 }), '3 rentals · 9 days · $450.50 on your statements · 1 not yet on a statement');
});
