// Unit tests for the Email the renter form's choices (email-choices.ts, migration 0187): the adjuster and the Blind Spot
// Car Rental sender only on an insurer-billed booking, the adjuster always from Blind Spot Car Rental.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { emailKind, emailProblem, pickSender, recipientChoices, senderChoices, usageLine } from './email-choices.ts';

const renterOnly = { insurer_billed: false, renter: { name: 'Maya Chen', email: 'maya@example.test' }, adjuster: null };
const insurer = { insurer_billed: true, renter: { name: 'Maya Chen', email: 'maya@example.test' }, adjuster: { name: 'Alex Adjuster', email: 'alex@example.test' } };

test('a renter-billed booking: the renter only, from CarmaCars only', () => {
  assert.deepEqual(recipientChoices(renterOnly).map(([k]) => k), ['renter']);
  assert.deepEqual(senderChoices(renterOnly, 'renter').map(([k]) => k), ['carmacars']);
  assert.equal(pickSender(renterOnly, 'renter', 'blindspot'), 'carmacars');
});

test('an insurer-billed booking: the adjuster too; the renter may hear from either sender', () => {
  assert.deepEqual(recipientChoices(insurer), [['renter', 'The renter, Maya Chen'], ['adjuster', 'The adjuster, Alex Adjuster']]);
  assert.deepEqual(senderChoices(insurer, 'renter').map(([k]) => k), ['carmacars', 'blindspot']);
  assert.equal(pickSender(insurer, 'renter'), 'carmacars');
  assert.equal(pickSender(insurer, 'renter', 'blindspot'), 'blindspot');
});

test('the adjuster always hears from Blind Spot Car Rental', () => {
  assert.deepEqual(senderChoices(insurer, 'adjuster'), [['blindspot', 'Blind Spot Car Rental (insurance)']]);
  assert.equal(pickSender(insurer, 'adjuster', 'carmacars'), 'blindspot');
});

test('no adjuster without their email, even when an insurer pays', () => {
  assert.deepEqual(recipientChoices({ ...insurer, adjuster: { name: 'Alex Adjuster', email: null } }).map(([k]) => k), ['renter']);
});

test('the form needs a subject and a message, within their limits', () => {
  assert.equal(emailProblem(' ', 'Hello'), 'Write the subject.');
  assert.equal(emailProblem('Hi', '  '), 'Write the message.');
  assert.equal(emailProblem('x'.repeat(151), 'Hello'), 'Keep the subject under 150 characters.');
  assert.equal(emailProblem('Hi', 'x'.repeat(4001)), 'Keep the message under 4,000 characters.');
  assert.equal(emailProblem('Hi', 'Hello'), null);
});

test('the list names the emails in plain words', () => {
  assert.equal(emailKind('renter_staff_message'), 'Message from staff');
  assert.equal(emailKind('insurance_staff_message'), 'Message from Blind Spot Car Rental');
  assert.equal(emailKind('renter_booking_confirmed'), 'Booking confirmed');
});

test('the daily limit line warns from 80%', () => {
  assert.equal(usageLine({ total: 79, cap: 100 }).warn, false);
  assert.equal(usageLine({ total: 80, cap: 100 }).warn, true);
  assert.match(usageLine({ total: 12, cap: 100 }).text, /^12 of 100 emails used today\./);
});
