import { test } from 'node:test';
import assert from 'node:assert/strict';
import { friendlyDbError, friendlyText, isRawDbError, maskPersonal } from './friendly.ts';

test('the database\'s own refusals pass through as written', () => {
  for (const e of [
    { message: 'Do not release the car: the Tracker is not in place and reporting', code: '23514' },
    { message: 'Enter the e-Transfer reference number', code: '22023' },
    { message: 'Only field staff may do this', code: '42501' },
    { message: 'Booking CC-10001 not found', code: 'P0001' }
  ]) {
    assert.equal(isRawDbError(e), false, e.message);
    assert.equal(friendlyDbError(e), e);
  }
});

test('raw PostgreSQL errors are recognised', () => {
  for (const e of [
    { message: 'new row for relation "bookings" violates check constraint "bookings_bill_to_insurer"', code: '23514' },
    { message: 'duplicate key value violates unique constraint "x_key"', code: '23505' },
    { message: 'invalid input syntax for type uuid: "abc"', code: '22P02' },
    { message: 'column "foo" of relation "bar" does not exist', code: '42703' },
    { message: 'canceling statement due to statement timeout', code: '57014' },
    { message: 'null value in column "amount_cents" of relation "payments" violates not-null constraint', code: '23502' },
    { message: 'record "u" has no field "kind"', code: '42703' }
  ]) assert.equal(isRawDbError(e), true, e.message);
});

test('each kind reads as a plain sentence with the reference', () => {
  assert.match(friendlyText({ message: 'duplicate key value violates unique constraint "x"', code: '23505' }, 'E-ABC123'), /already recorded.*E-ABC123/);
  assert.match(friendlyText({ message: 'insert or update on table "x" violates foreign key constraint "y"', code: '23503' }, 'E-1'), /no longer exists/);
  assert.match(friendlyText({ message: 'new row for relation "x" violates check constraint "y"', code: '23514' }, 'E-1'), /missing or not allowed/);
  assert.match(friendlyText({ message: 'canceling statement due to statement timeout', code: '57014' }, 'E-1'), /busy/);
  const out = friendlyDbError({ message: 'new row for relation "bookings" violates check constraint "bookings_bill_to_insurer"', code: '23514' }, { call: 'field_do' });
  assert.ok(out instanceof Error);
  assert.doesNotMatch(out.message, /constraint|relation|bookings_/);
  assert.match(out.message, /reference E-[0-9A-Z]{6}/);
});

test('the log masks email addresses and phone numbers', () => {
  assert.equal(maskPersonal('Key (email)=(riley.renter@example.test) already exists'), 'Key (email)=([email]) already exists');
  assert.equal(maskPersonal('mobile +1 (647) 555-0123 taken'), 'mobile [number] taken');
});

test('a constraint a person can act on is named in words (0148)', () => {
  assert.match(friendlyText({ message: 'new row for relation "bookings" violates check constraint "bookings_bill_to_insurer"', code: '23514' }, 'E-1'), /pick the insurer.*E-1/);
  assert.match(friendlyText({ message: 'duplicate key value violates unique constraint "renters_email_key"', code: '23505' }, 'E-2'), /find them by email/);
});
