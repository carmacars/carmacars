// The database's own refusals in words (src/lib/db/friendly.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { friendlyDbMessage } from './friendly.ts';

test('names the insurer when bill_to insurer has none', () => {
  assert.match(friendlyDbMessage('new row for relation "bookings" violates check constraint "bookings_bill_to_insurer"'), /pick the insurer/);
});
test('turns an unknown check into a sentence', () => {
  assert.match(friendlyDbMessage('ERROR:  new row for relation "x" violates check constraint "x_check"'), /not allowed here/);
});
test('turns a missing value into a sentence with the field', () => {
  assert.equal(friendlyDbMessage('null value in column "legal_name" of relation "renters" violates not-null constraint'), 'Something required is missing (legal name). Fill it in and try again.');
});
test('leaves our own sentences alone', () => {
  assert.equal(friendlyDbMessage('The car is not free for these dates'), 'The car is not free for these dates');
});
