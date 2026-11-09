// The field staff portal (r35 part X): tabs, card words and steps, the SIN check, money typed.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { activeTab, cardSteps, cardTitle, fieldTabs, isLate, nextStep, sinShown, toCents, validSin, type Card } from './model.ts';

const car = { id: 'v', name: '2024 Example Sedan', plate: 'ABCD 123' };
const pickup = (x: Partial<Card> = {}): Card => ({ type: 'job', key: 'job:1', must: true, done: false, kind: 'handover', leg: 'pickup', status: 'acknowledged', vehicle: car,
  clean: { moment: 'before_pickup', done: false }, addons: [{ id: 'a', name: 'Child seat', quantity: 1, note: null, ticked: false, ticked_at: null, ticked_by: null }], addons_open: 1, ...x });

test('at most four tabs, and Sales only for a person who opted in', () => {
  assert.deepEqual(fieldTabs({}).map((t) => t.label), ['Today', 'My shifts', 'My pay', 'Training']);
  assert.deepEqual(fieldTabs({ salesOptIn: true }).map((t) => t.label), ['Today', 'My shifts', 'My pay', 'Training', 'Sales']);
});

test('each address belongs to one tab; the old ones to their new place', () => {
  assert.equal(activeTab('/staff/field'), 'today');
  assert.equal(activeTab('/staff/field/jobs/x'), 'today');
  assert.equal(activeTab('/staff/field/help/CC-1'), 'today');
  assert.equal(activeTab('/staff/field/hours'), 'pay');
  assert.equal(activeTab('/staff/field/shifts'), 'shifts');
  assert.equal(activeTab('/staff/field/guide'), 'training');
  assert.equal(activeTab('/staff/field/rentals/new'), 'sales');
});

test('one primary step per card: the job screen first, a missing clean check last', () => {
  assert.equal(nextStep(pickup()).label, 'Start the pickup');
  assert.equal(nextStep(pickup({ leg: 'return', kind: 'return_check_in' })).label, 'Start the return');
  assert.equal(nextStep(pickup({ leg: 'return', kind: 'return_check_in', status: 'done', clean: { moment: 'after_return', done: false } })).what, 'clean');
  assert.equal(nextStep(pickup({ done: true })).what, 'done');
  assert.equal(nextStep({ type: 'photos', key: 'p', must: false, done: false, vehicle: car }).label, 'Take the photos');
  assert.equal(nextStep({ type: 'clean', key: 'c', must: false, done: false, vehicle: car }).what, 'clean');
});

test('a car and time is one card: clean check, add-ons and the handover are its steps', () => {
  assert.deepEqual(cardSteps(pickup()).map((s) => s.label), ['Clean check (tick and photo)', 'Add-ons in the car (0 of 1)', 'Pickup photos and handover']);
  assert.deepEqual(cardSteps(pickup({ leg: 'return', kind: 'return_check_in', clean: { moment: 'after_return', done: true } })).map((s) => s.done), [false, true]);
  assert.equal(cardTitle({ type: 'job', kind: 'delivery' }), 'Delivery to the renter');
  assert.equal(cardTitle({ type: 'service' }), 'Needs service');
});

test('the SIN: nine digits that pass the check, shown with the last three only', () => {
  assert.equal(validSin('046 454 286'), true);
  assert.equal(validSin('046-454-287'), false);
  assert.equal(validSin('12345678'), false);
  assert.equal(validSin('000000000'), false);
  assert.equal(sinShown('286'), '***-***-286');
});

test('money typed to cents', () => {
  assert.equal(toCents('12.50'), 1250);
  assert.equal(toCents('$1,200'), 120000);
  assert.equal(toCents(''), null);
  assert.equal(toCents('12.505'), null);
});

test('a give-up under 24 hours before the start is late', () => {
  const now = Date.parse('2026-11-08T12:00:00Z');
  assert.equal(isLate('2026-11-09T10:00:00Z', now), true);
  assert.equal(isLate('2026-11-10T10:00:00Z', now), false);
});
