// Unit tests for Turo sync by email (migration 0063): the sample emails in samples/ are in the shapes Turo sends hosts
// (booked, booked with a one-line range and no year, changed with the old and new dates, extended across the end of
// daylight saving, cancelled, a booking request, a car that cannot be told apart, forwarded by hand) and Gmail's
// forwarding confirmation. They are written for these tests, not captured from the CarmaCars account.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { classify, decodeWords, findDates, gmailConfirmation, mergeAi, parseMime, parseTuroEmail, plainAddress, redact, torontoToUtc, type MatchCar } from './email.ts';

const raw = (f: string) => readFileSync(join(import.meta.dirname, 'samples', `${f}.eml`), 'utf8');
const CARS: MatchCar[] = [
  { vehicle_id: 'glc21', name: '2021 Mercedes-Benz GLC 300', listing_name: 'Mercedes-Benz GLC 2021', turo_vehicle_id: '2711093', plate: 'CMRA 100', vin: 'W1N0G8EB5MF000001', make: 'Mercedes-Benz', model: 'GLC 300', year: 2021 },
  { vehicle_id: 'glc22', name: '2022 Mercedes-Benz GLC 300', listing_name: null, turo_vehicle_id: null, plate: 'CMRA 222', vin: null, make: 'Mercedes-Benz', model: 'GLC', year: 2022 },
  { vehicle_id: 'c300', name: '2024 Mercedes-Benz C 300', listing_name: 'Mercedes-Benz C-Class 2024', turo_vehicle_id: null, plate: 'CKRT 482', vin: null, make: 'Mercedes-Benz', model: 'C 300', year: 2024 }
];
const parse = (f: string) => parseTuroEmail(parseMime(raw(f)), CARS);

test('booked: an HTML table (quoted-printable), the encoded subject, the Turo car link, Toronto time to UTC', () => {
  const m = parseMime(raw('booked'));
  assert.match(m.subject, /^Ayesha booked your Mercedes-Benz GLC 2021/);
  const p = parseTuroEmail(m, CARS);
  assert.equal(p.kind, 'booked');
  assert.equal(p.fromTuro, true);
  assert.equal(p.tripId, '48211907');
  assert.equal(p.start, '2026-10-22T14:00:00.000Z'); // 10:00 EDT
  assert.equal(p.end, '2026-10-25T14:00:00.000Z');
  assert.equal(p.guestFirstName, 'Ayesha');
  assert.equal(p.vehicleId, 'glc21');
  assert.match(p.vehicleWhy ?? '', /Turo car 2711093/);
  assert.deepEqual(p.missing, []);
});

test('booked: plain text, a one-line range with no year (the email date decides it), matched by the plate', () => {
  const p = parse('booked-range');
  assert.equal(p.kind, 'booked');
  assert.equal(p.tripId, '51002233');
  assert.equal(p.start, '2026-10-30T22:00:00.000Z'); // 6:00 PM EDT
  assert.equal(p.end, '2026-11-02T14:00:00.000Z'); // 9:00 AM EST, after the change on Nov 1
  assert.equal(p.guestFirstName, 'Daniel');
  assert.equal(p.vehicleId, 'c300');
  assert.match(p.vehicleWhy ?? '', /plate CKRT 482/);
});

test('changed: the new dates win over the previous ones (base64 HTML)', () => {
  const p = parse('changed');
  assert.equal(p.kind, 'changed');
  assert.equal(p.tripId, '48211907');
  assert.equal(p.start, '2026-10-23T16:00:00.000Z');
  assert.equal(p.end, '2026-10-26T14:00:00.000Z');
  assert.equal(p.vehicleId, 'glc21');
});

test('extended: the new end across the end of daylight saving; the start as written', () => {
  const p = parse('extended');
  assert.equal(p.kind, 'extended');
  assert.equal(p.tripId, '48211907');
  assert.equal(p.end, '2026-11-02T15:00:00.000Z'); // 10:00 EST
  assert.equal(p.start, '2026-10-23T16:00:00.000Z');
  assert.deepEqual(p.missing, []);
});

test('cancelled: kind and trip id; no dates are needed', () => {
  const p = parse('cancelled');
  assert.equal(p.kind, 'cancelled');
  assert.equal(p.tripId, '48211907');
  assert.equal(p.start, null);
  assert.deepEqual(p.missing, []);
});

test('a booking request is not a trip yet; Turo marketing and other emails are "other"', () => {
  assert.equal(parse('request').kind, 'request');
  assert.equal(classify('Your payout is on the way', 'You earned $412.50 this week.'), 'other');
  assert.equal(classify('Earn more this holiday season', 'Hosts who update their calendar ...'), 'other');
});

test('a car that cannot be told apart goes to review with what the email calls it', () => {
  const p = parse('unclear');
  assert.equal(p.kind, 'booked');
  assert.equal(p.vehicleId, null);
  assert.deepEqual(p.missing, ['car']);
  assert.match(p.vehicleWhy ?? '', /matches 2 cars/);
  assert.equal(p.vehicleHint, 'Mercedes-Benz GLC');
  assert.equal(p.start, '2026-11-06T15:00:00.000Z');
});

test('forwarded by hand: the inner Turo message is read, the Fwd: prefix dropped, Turo recognised from the forwarded From line', () => {
  const p = parse('forwarded-by-hand');
  assert.equal(p.fromTuro, true);
  assert.equal(p.kind, 'booked');
  assert.equal(p.tripId, '53100042');
  assert.equal(p.guestFirstName, 'Sam');
  assert.equal(p.start, '2026-11-14T16:00:00.000Z');
  assert.equal(p.vehicleId, 'c300');
});

test('Gmail forwarding confirmation: the code and the link (Google hosts only); other mail is not one', () => {
  const g = gmailConfirmation(parseMime(raw('gmail-confirmation')));
  assert.deepEqual(g, { code: '418377214', url: 'https://mail-settings.google.com/mail/vf-%5BANGjdJ8x2b%5D-AbCdEf0123456789', forAddress: 'rent@carmacars.ca' });
  assert.equal(gmailConfirmation(parseMime(raw('booked'))), null);
  const fake = parseMime('From: Gmail Team <forwarding-noreply@google.com.evil.example>\nSubject: (#1234567) Gmail Forwarding Confirmation\n\nhttps://evil.example/mail/x');
  assert.equal(gmailConfirmation(fake), null);
});

test('not from Turo: another sender is recognised as such', () => {
  const m = parseMime('From: Someone <a@b.example>\nSubject: Jane booked your Mercedes-Benz GLC 2021\n\nTrip start: Oct 22, 2026 10:00 AM\nTrip end: Oct 23, 2026 10:00 AM\nReservation ID 12345678');
  assert.equal(parseTuroEmail(m, CARS).fromTuro, false);
});

test('the excerpt kept for review has no address, phone or link, and is short', () => {
  const text = parseMime(raw('booked')).text;
  const r = redact(text);
  assert.ok(r.length <= 600);
  assert.doesNotMatch(r, /@|555-0199|https?:/);
  assert.match(redact('See https://turo.com/ca/en/reservation/48211907 or call 647-555-0123, mail a@b.co'), /\[Turo link 48211907\] or call \[phone\], mail \[email\]/);
});

test('helpers: encoded words, Gmail\'s forwarding envelope, dates in words and numbers, both daylight saving changes', () => {
  assert.equal(decodeWords('=?UTF-8?B?VHJpcCBib29rZWQ=?= =?UTF-8?Q?_now?='), 'Trip booked now');
  assert.equal(plainAddress('<rent+caf_=trips=in.carmacars.ca@carmacars.ca>'), 'rent@carmacars.ca');
  const e = new Date('2026-12-20T12:00:00Z');
  assert.deepEqual(findDates('From January 3 at 9:30 pm to 01/05/2027 8:00 AM, then 2027-01-09 13:15', e).map((d) => d.at.toISOString()),
    ['2027-01-04T02:30:00.000Z', '2027-01-05T13:00:00.000Z', '2027-01-09T18:15:00.000Z']);
  assert.equal(torontoToUtc(2026, 3, 8, 3, 0).toISOString(), '2026-03-08T07:00:00.000Z'); // the first hour of daylight time
  assert.equal(torontoToUtc(2026, 11, 1, 12, 0).toISOString(), '2026-11-01T17:00:00.000Z');
});

test('the model only fills what the rules missed, and only with values the email contains', () => {
  const m = parseMime('From: Turo <noreply@mail.turo.com>\nDate: Mon, 19 Oct 2026 09:00:00 -0400\nSubject: Update on your trip\n\n' +
    'Lina is all set in your Mercedes-Benz GLC 2021. Pick it up Thursday October 29 2026, 3:30 PM and bring it back Saturday October 31 2026, 3:30 PM. Ref 49900123');
  const p = parseTuroEmail(m, CARS);
  assert.equal(p.kind, 'other');
  const merged = mergeAi(p, { kind: 'booked', start: '2026-10-29 15:30', end: '2026-10-31 15:30', trip_id: '49900123', guest_first_name: 'Lina', car: 'Mercedes-Benz GLC 2021' }, m, CARS);
  assert.equal(merged.kind, 'booked');
  assert.equal(merged.start, '2026-10-29T19:30:00.000Z');
  assert.equal(merged.end, '2026-10-31T19:30:00.000Z');
  assert.equal(merged.tripId, '49900123');
  assert.equal(merged.vehicleId, 'glc21');
  assert.deepEqual(merged.missing, []);
  // invented values are refused: a date the email does not contain, a trip id not in it, a name with digits
  const bad = mergeAi(p, { kind: 'booked', start: '2026-10-28 15:30', end: '2026-10-31 15:30', trip_id: '11111111', guest_first_name: 'L1na', car: 'Toyota Corolla' }, m, CARS);
  assert.equal(bad.start, null);
  assert.equal(bad.tripId, null);
  assert.equal(bad.guestFirstName, null);
  assert.equal(bad.vehicleId, 'glc21'); // the rules found the car; the model's "Toyota Corolla" is not used
  assert.deepEqual(bad.missing, ['start', 'trip id']);
});
