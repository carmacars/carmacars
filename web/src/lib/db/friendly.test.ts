import { describe, expect, it } from 'vitest';
import { friendlyDbMessage } from './friendly';

describe('friendlyDbMessage', () => {
  it('names the insurer when bill_to insurer has none', () => {
    expect(friendlyDbMessage('new row for relation "bookings" violates check constraint "bookings_bill_to_insurer"')).toMatch(/pick the insurer/);
  });
  it('turns an unknown check into a sentence', () => {
    expect(friendlyDbMessage('ERROR:  new row for relation "x" violates check constraint "x_check"')).toMatch(/not allowed here/);
  });
  it('turns a missing value into a sentence with the field', () => {
    expect(friendlyDbMessage('null value in column "legal_name" of relation "renters" violates not-null constraint')).toBe('Something required is missing (legal name). Fill it in and try again.');
  });
  it('leaves our own sentences alone', () => {
    expect(friendlyDbMessage('The car is not free for these dates')).toBe('The car is not free for these dates');
  });
});
