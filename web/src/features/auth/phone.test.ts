import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CA_AREA_CODES, NANP_NOT_US, checkSignInPhone, cleanCode, formatPhone, isCanadianAreaCode, phoneCountry, toE164 } from './phone.ts';

// Sign-in by phone (migration 0091): numbers to E.164, Canadian area codes, who may get a code.

test('E.164: the ways people type a number, and what is not one', () => {
  for (const s of ['(647) 555-1234', '647 555 1234', '647.555.1234', '6475551234', '1-647-555-1234', '+1 647 555 1234', ' +16475551234 ']) assert.equal(toE164(s), '+16475551234', s);
  assert.equal(toE164('+44 20 7946 0958'), '+442079460958');
  for (const s of ['', null, undefined, '555-1234', '047 555 1234', '1 147 555 1234', 'call me', '+0 123 4567', '12345678901234567']) assert.equal(toE164(s as string), null, String(s));
});

test('Canadian area codes: Ontario, Quebec, the West, the North and the newest overlays; US and Caribbean codes are not', () => {
  for (const a of ['416', '647', '437', '905', '289', '365', '742', '683', '382', '387', '942', '753', '226', '519', '613', '343', '705', '249', '807', '514', '438', '263', '354', '468', '604', '778', '236', '672', '257', '403', '587', '825', '368', '780', '306', '639', '474', '204', '431', '584', '506', '428', '902', '782', '709', '867', '879'])
    assert.ok(isCanadianAreaCode(a), a);
  for (const a of ['212', '310', '917', '808', '876', '809', '800', '888', '600']) assert.ok(!isCanadianAreaCode(a), a);
  assert.equal(new Set(CA_AREA_CODES).size, CA_AREA_CODES.length);
  assert.ok(!CA_AREA_CODES.some((a) => NANP_NOT_US.includes(a)));
});

test('country: CA, US, or other (Caribbean, toll-free, N11, outside +1)', () => {
  assert.equal(phoneCountry('416 555 0101'), 'CA');
  assert.equal(phoneCountry('(289) 312-5991'), 'CA');
  assert.equal(phoneCountry('212 555 0101'), 'US');
  assert.equal(phoneCountry('808 555 0101'), 'US');
  assert.equal(phoneCountry('876 555 0101'), 'other');
  assert.equal(phoneCountry('800 555 0101'), 'other');
  assert.equal(phoneCountry('411 555 0101'), 'other');
  assert.equal(phoneCountry('416 155 0101'), 'other');
  assert.equal(phoneCountry('+44 20 7946 0958'), 'other');
  assert.equal(phoneCountry('hello'), null);
});

test('who may get a code: Canada always; the US only when an Admin allows it; never elsewhere', () => {
  assert.deepEqual(checkSignInPhone('647-555-1234', false), { ok: true, phone: '+16475551234', country: 'CA' });
  const us = checkSignInPhone('212 555 0101', false);
  assert.equal(us.ok, false);
  assert.equal(!us.ok && us.reason, 'country');
  assert.match(!us.ok ? us.message : '', /Canadian mobile numbers only/);
  assert.deepEqual(checkSignInPhone('212 555 0101', true), { ok: true, phone: '+12125550101', country: 'US' });
  assert.equal(checkSignInPhone('+44 20 7946 0958', true).ok, false);
  assert.equal(checkSignInPhone('12', true).ok, false);
});

test('display and codes', () => {
  assert.equal(formatPhone('+16475551234'), '(647) 555-1234');
  assert.equal(formatPhone('+442079460958'), '+442079460958');
  assert.equal(cleanCode('123 456'), '123456');
  assert.equal(cleanCode('123-456'), '123456');
  assert.equal(cleanCode('12345'), null);
  assert.equal(cleanCode('12a456'), null);
});

test('the area code lists are the same as the database migration', () => {
  const sql = readFileSync(new URL('../../../../supabase/migrations/0091_phone_sign_in.sql', import.meta.url), 'utf8');
  const list = (fn: string) => {
    const m = new RegExp(`function app\\.${fn}\\(\\)[\\s\\S]*?select array\\[([\\s\\S]*?)\\]`).exec(sql);
    assert.ok(m, fn);
    return [...m[1]!.matchAll(/'(\d{3})'/g)].map((x) => x[1]);
  };
  assert.deepEqual(list('phone_ca_area_codes'), [...CA_AREA_CODES]);
  assert.deepEqual(list('phone_nanp_not_us'), [...NANP_NOT_US]);
});
