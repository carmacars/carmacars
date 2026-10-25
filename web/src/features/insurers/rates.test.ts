import { test } from 'node:test';
import assert from 'node:assert/strict';
import { billingCsv, billingFileName, prefillRate, rateAmount, rateCheck, rateLine, type BillingRow } from './rates.ts';

test('a rate under its caps comes to what the database works out (app.insurer_rate_amount)', () => {
  assert.equal(rateAmount(6500, null, null, 10), 65000);
  assert.equal(rateAmount(6500, 39000, null, 10), 58500);
  assert.equal(rateAmount(6500, 30000, null, 6), 30000);
  assert.equal(rateAmount(6500, 39000, null, 5), 32500);
  assert.equal(rateAmount(6500, 39000, 120000, 45), 204500);
  assert.equal(rateAmount(6500, 39000, 120000, 0), 0);
  assert.equal(rateAmount(null, 39000, null, 3), 0);
});

test('a sheet row reads as one line', () => {
  assert.equal(rateLine({ daily_rate_cents: 6500, weekly_cap_cents: 39000, delivery_allowance_cents: 5000, km_per_day: 250 }),
    '$65.00 a day, at most $390.00 a week, delivery and pickup up to $50.00, 250 km a day');
  assert.equal(rateLine({ daily_rate_cents: 6500, km_per_day: 0 }), '$65.00 a day, unlimited km');
  assert.equal(rateLine({ daily_rate_cents: null }), 'No rate');
});

test('a rate typed is checked against the sheet', () => {
  const sheet = { class_code: 'sedan', class_label: 'Sedan', daily_rate_cents: 6500 };
  assert.equal(rateCheck(7000, null).state, 'none');
  assert.equal(rateCheck(undefined, sheet).state, 'empty');
  assert.equal(rateCheck(6500, sheet).state, 'sheet');
  const d = rateCheck(7000, sheet, 'Allstate');
  assert.equal(d.state, 'differs');
  assert.equal(d.state === 'differs' && d.message, '$70.00 a day differs from Allstate\'s rate sheet for Sedan ($65.00): say why.');
});

test('the form fills the sheet\'s rate unless staff typed one', () => {
  const allstate = { class_code: 'sedan', daily_rate_cents: 6500 };
  const other = { class_code: 'sedan', daily_rate_cents: 6000 };
  assert.equal(prefillRate('', null, allstate), '65.00');
  assert.equal(prefillRate('65.00', '65.00', other), '60.00');   // filled before, another insurer chosen
  assert.equal(prefillRate('72.00', '65.00', other), '72.00');   // typed by hand: kept
  assert.equal(prefillRate('65.00', '65.00', null), '');         // the new insurer has no sheet: the filled rate goes
});

test('the billing history exports as CSV, safe for a spreadsheet', () => {
  const row: BillingRow = { booking_number: 'CC-10001', status: 'closed', pickup_at: '2026-10-01T14:00:00Z', return_at: '2026-10-11T14:00:00Z', class_label: 'Sedan', class_code: 'sedan',
    vehicle: '2024 Volkswagen Jetta', renter: 'Ira, "Rated"', claim_number: '=HYPERLINK("x")', bill_to: 'insurer', days_authorized: 10, days_used: 10, days_covered: 10,
    daily_rate_cents: 6500, rate_source: 'sheet', sheet_rate_cents: 6500, rate_reason: null, share_cents: 66105, billed_cents: 66105, paid_cents: 66105,
    outstanding_cents: 0, written_off_cents: 0, days_to_pay: 12, invoices: [{ invoice_number: 'INS-5001', status: 'paid' }] };
  const csv = billingCsv('Allstate', [row]);
  const [head, line] = csv.split('\r\n');
  assert.ok(head!.startsWith('Insurer,Booking,Status,Class'));
  assert.ok(line!.includes('"Ira, ""Rated"""'));
  assert.ok(line!.includes('"\'=HYPERLINK(""x"")"'), 'a formula is never run by the spreadsheet');
  assert.ok(line!.includes(',2026-10-01,2026-10-11,Rental and fees,10,10,10,65.00,Rate sheet,65.00,,661.05,661.05,661.05,0.00,0.00,12,INS-5001 (paid)'));
  assert.ok(csv.endsWith('\r\n'));
  assert.equal(billingFileName('Allstate Insurance Co.', '2026-10-25'), 'carmacars-insurer-allstate-insurance-co-2026-10-25.csv');
});
