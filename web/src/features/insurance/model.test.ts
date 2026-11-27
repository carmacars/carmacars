import { test } from 'node:test';
import assert from 'node:assert/strict';
import { diffVersions, lineAmount, mergeParsed, parseClaimText, readDate, rentalDays, totals, type Snapshot } from './model.ts';

const EMAIL = `From: Pat Example <pat.adjuster@definity.example.test>
Subject: Rental authorization, Claim # 000-00-313318

Hi team,
Please set up a replacement vehicle for our insured.
Insured: Dana Example
Phone: (416) 555-0199
Start date: Nov 3, 2026
End date: 11/20/2026
We have authorized 17 days at $65.00 per day.

Regards,
Pat Example
Claims Adjuster
519-555-0163`;

test('reads an adjuster email: claim, renter, adjuster, insurer, dates, days and rate', () => {
  const p = parseClaimText(EMAIL, ['Definity', 'Intact'], 2026);
  assert.equal(p.claim_number, '000-00-313318');
  assert.equal(p.renter_name, 'Dana Example');
  assert.equal(p.renter_phone, '4165550199');
  assert.equal(p.adjuster_name, 'Pat Example');
  assert.equal(p.adjuster_email, 'pat.adjuster@definity.example.test');
  assert.equal(p.adjuster_phone, '5195550163');
  assert.equal(p.insurer_name, 'Definity');
  assert.equal(p.pickup_date, '2026-11-03');
  assert.equal(p.return_date, '2026-11-20');
  assert.equal(p.authorized_days, 17);
  assert.equal(p.daily_rate_cents, 6500);
});

test('never invents what the text does not say', () => {
  assert.deepEqual(parseClaimText('Please call me back about the car.'), {});
});

test('a labelled vehicle and plate are read', () => {
  const p = parseClaimText('Vehicle: 2024 Toyota Corolla LE\nPlate: CDEF 123\nClaimant: Lee Example');
  assert.deepEqual([p.car_year, p.car_make, p.car_model, p.car_plate, p.renter_name], [2024, 'Toyota', 'Corolla LE', 'CDEF123', 'Lee Example']);
});

test('dates in the forms insurers write them', () => {
  assert.equal(readDate('2026-11-3'), '2026-11-03');
  assert.equal(readDate('3 November 2026'), '2026-11-03');
  assert.equal(readDate('Dec 1st', 2026), '2026-12-01');
  assert.equal(readDate('soon'), undefined);
});

test('the AI fills only what the rules left empty, and only well-formed values', () => {
  const m = mergeParsed({ claim_number: 'A-1234' }, { claim_number: 'X-9999', renter_name: 'Ana Example', renter_email: 'not an email', pickup_date: '2026-13', authorized_days: 12, daily_rate_cents: -5 });
  assert.deepEqual(m, { claim_number: 'A-1234', renter_name: 'Ana Example', authorized_days: 12 });
});

test('line amounts and totals: quantity times rate, HST on taxable lines only unless typed', () => {
  assert.equal(lineAmount({ quantity: 3, rate_cents: 6500 }), 19500);
  assert.equal(lineAmount({ quantity: 3, rate_cents: 6500, amount_cents: 100 }), 100);
  const lines = [{ description: 'Rental', quantity: 10, rate_cents: 6500, amount_cents: 65000 }, { description: 'Winter tire fee', amount_cents: 5000 }, { description: 'Admin', amount_cents: 1000, taxable: false }];
  assert.deepEqual(totals(lines, 1300), { amount_cents: 71000, hst_cents: 9100, total_cents: 80100 });
  assert.deepEqual(totals(lines, 1300, 0), { amount_cents: 71000, hst_cents: 0, total_cents: 71000 });
});

test('days count a started day', () => {
  assert.equal(rentalDays('2026-11-01T15:00:00Z', '2026-11-04T15:00:00Z'), 3);
  assert.equal(rentalDays('2026-11-01T15:00:00Z', '2026-11-04T16:00:00Z'), 4);
});

test('a new version lists what changed and nothing else', () => {
  const a: Snapshot = { lines: [{ description: 'Rental', quantity: 10, rate_cents: 6500, amount_cents: 65000 }], amount_cents: 65000, hst_cents: 8450, total_cents: 73450, period_start: '2026-11-01', period_end: '2026-11-11', notes: null };
  const b: Snapshot = { ...a, lines: [{ description: 'Rental', quantity: 14, rate_cents: 6500, amount_cents: 91000 }, { description: 'Winter tire fee', amount_cents: 5000 }],
    amount_cents: 96000, hst_cents: 12480, total_cents: 108480, period_end: '2026-11-15' };
  const d = diffVersions(a, b);
  assert.deepEqual(d.map((r) => r.label), ['Line: Rental', 'Line: Winter tire fee', 'Before HST', 'HST', 'Total', 'Rental period']);
  assert.equal(d[0]!.after, '14 x $65.00 = $910.00');
  assert.equal(d[1]!.before, 'none');
  assert.deepEqual(diffVersions(a, a), []);
  assert.deepEqual(diffVersions(null, a), []);
});
