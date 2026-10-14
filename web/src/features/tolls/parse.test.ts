import { test } from 'node:test';
import assert from 'node:assert/strict';
import { csvLines, findDate, findPlate, findTime, moneyTokens, parseCsv, pickProfile, readText, type Profile, type TextLine } from './parse.ts';

// The reading profiles as migration 0042 seeds them (the rules an Admin edits).
const P407: Profile = { id: 'p1', operator: '407 ETR', name: '407 ETR statement', source: 'pdf_text', notice_kind: 'toll_invoice', priority: 10, rules: {
  layout: 'statement', detect: ['407 ETR', '407etr', 'Express Toll Route'], authority: '407 ETR', date_order: 'auto',
  fields: { statement_number: ['Statement Number', 'Invoice Number'], account_number: ['Account Number'], statement_date: ['Statement Date'], due_on: ['Payment Due Date', 'Due Date'], total: ['Total Amount Due', 'Amount Due'] },
  trip: { skip_words: ['Previous Balance', 'Payment Received', 'Subtotal', 'Total', 'Balance'], statement_fee_words: ['Account Fee', 'Late Payment'] } } };
const PARK: Profile = { id: 'p3', operator: 'Ontario parking or penalty notice', name: 'Parking', source: 'pdf_text', notice_kind: 'parking', priority: 30, rules: {
  layout: 'single', detect: ['Parking', 'Penalty Notice'], date_order: 'auto',
  fields: { authority: ['Municipality', 'Issued by'], notice_number: ['Penalty Notice Number', 'Notice Number'], plate: ['Licence Plate Number', 'Plate'],
            date: ['Date of Infraction', 'Date'], time: ['Time of Infraction', 'Time'], place: ['Location'], amount: ['Penalty Amount', 'Amount Due'], due_on: ['Due Date'] } } };
const GEN: Profile = { id: 'p5', operator: 'Other issuer', name: 'Any notice', source: 'pdf_text', notice_kind: 'fine', priority: 900, rules: { layout: 'auto', detect: [],
  fields: { notice_number: ['Notice Number'], plate: ['Plate'], date: ['Date'], amount: ['Amount Due', 'Amount'] }, trip: { skip_words: ['Total'] } } };
const lines = (text: string, page = 1): TextLine[] => text.split('\n').map((t, i, a) => ({ text: t, page, y: i / a.length, h: 1 / a.length }));
const FLEET = ['CCAB123', 'TXYZ789'];

test('money: dollars and cents, thousands, not a distance in km', () => {
  assert.deepEqual(moneyTokens('2026-09-14 Hwy 400 to Dufferin 23.45 km $8.14 $4.20 1,234.50').map((t) => t.cents), [814, 420, 123450]);
});

test('dates: ISO, numeric both ways, month names; an unclear order is flagged', () => {
  assert.equal(findDate('Trip 2026-09-14 08:12')!.iso, '2026-09-14');
  assert.equal(findDate('on 14/09/2026')!.iso, '2026-09-14');
  assert.equal(findDate('on 09/14/2026')!.iso, '2026-09-14');
  assert.equal(findDate('Sep 14, 2026')!.iso, '2026-09-14');
  assert.equal(findDate('14-Sept-2026')!.iso, '2026-09-14');
  assert.equal(findDate('03/04/2026')!.ambiguous, true);
  assert.equal(findDate('03/04/2026', 'dmy')!.iso, '2026-04-03');
  assert.equal(findDate('no date here'), null);
});

test('times: 12-hour and 24-hour clocks', () => {
  assert.equal(findTime('at 8:12 PM')!.hhmm, '20:12');
  assert.equal(findTime('at 12:05 a.m.')!.hhmm, '00:05');
  assert.equal(findTime('20:41:09')!.hhmm, '20:41');
  assert.equal(findTime('$12.34'), null);
});

test('plates: the fleet first (with a space), else the shape of an Ontario plate', () => {
  const fleet = new Set(FLEET);
  assert.deepEqual(findPlate('Plate CCAB 123 trip', fleet), { plate: 'CCAB123', inFleet: true, raw: 'CCAB123' });
  assert.deepEqual(findPlate('Plate ZZZZ 999', fleet), { plate: 'ZZZZ999', inFleet: false, raw: 'ZZZZ999' });
  assert.equal(findPlate('Account 123456789', fleet), null);
});

test('the profile is picked by its words; the general one when nothing matches', () => {
  assert.equal(pickProfile('407 ETR Express Toll Route statement', [GEN, PARK, P407])!.id, 'p1');
  assert.equal(pickProfile('City of Toronto Penalty Notice', [GEN, PARK, P407])!.id, 'p3');
  assert.equal(pickProfile('A letter about something', [GEN, PARK, P407])!.id, 'p5');
});

const STATEMENT = `407 ETR Express Toll Route
Statement Number: ST-55120931   Statement Date: Oct 1, 2026
Account Number: 1234-5678
Payment Due Date: October 26, 2026
Previous Balance $0.00
Trip Date  Time  Entry  Exit  Distance  Plate  Toll  Camera Charge  Total
2026-09-14  8:12 PM  Highway 400  Dufferin St  23.45 km  CCAB 123  $8.14  $4.20  $12.34
2026-09-15  07:03  Brock Rd  Highway 427  41.10 km  CCAB 123  $16.20  $4.20  $20.40
2026-09-16  11:45 AM  Yonge St  Keele St  6.02 km  ZZZZ 999  $2.10  $4.20  $6.30
Monthly Account Fee  $4.25
Total Amount Due  $43.29`;

test('407 ETR statement: header, one line per trip with entry and exit, fees, the account fee apart, the total checked', () => {
  const r = readText(lines(STATEMENT), P407, { plates: FLEET });
  assert.equal(r.layout, 'statement');
  assert.equal(r.authority, '407 ETR');
  assert.equal(r.statement_number, 'ST-55120931');
  assert.equal(r.account_number, '1234-5678');
  assert.equal(r.statement_date, '2026-10-01');
  assert.equal(r.due_on, '2026-10-26');
  assert.equal(r.total_cents, 4329);
  assert.equal(r.lines.length, 3);
  const [a, b, c] = r.lines;
  assert.deepEqual([a!.occurred_at, a!.plate, a!.entry, a!.exit, a!.amount_cents, a!.fees_cents, a!.time_unknown], ['2026-09-14T20:12:00', 'CCAB123', 'Highway 400', 'Dufferin St', 1234, 420, false]);
  assert.equal(b!.occurred_at, '2026-09-15T07:03:00');
  assert.ok(a!.confidence >= 90, `confidence ${a!.confidence}`);
  assert.ok(c!.confidence < 80, 'a plate not in the fleet lowers the confidence');
  assert.deepEqual(r.statement_fees, [{ text: 'Monthly Account Fee  $4.25', amount_cents: 425 }]);
  assert.deepEqual(r.problems, []);
});

test('407 ETR statement: a total that does not add up is said', () => {
  const r = readText(lines(STATEMENT.replace('$43.29', '$50.00')), P407, { plates: FLEET });
  assert.match(r.problems.join(' '), /add up to 43\.29, the statement says 50\.00/);
});

const PARKING = `City of Toronto
Penalty Notice
Penalty Notice Number: PN 4410-2291
Licence Plate Number: TXYZ789   Province: ON
Date of Infraction: 2026-09-23   Time of Infraction: 2:32 PM
Location: 100 Queen St W
Penalty Amount: $50.00
Due Date: 2026-10-23`;

test('parking notice: one line with every field', () => {
  const r = readText(lines(PARKING), PARK, { plates: FLEET });
  assert.equal(r.layout, 'single');
  assert.equal(r.lines.length, 1);
  const l = r.lines[0]!;
  assert.deepEqual([l.kind, l.notice_number, l.plate, l.occurred_at, l.place, l.amount_cents, l.due_on], ['parking', 'PN 4410-2291', 'TXYZ789', '2026-09-23T14:32:00', '100 Queen St W', 5000, '2026-10-23']);
  assert.ok(l.confidence >= 85, `confidence ${l.confidence}`);
});

test('the general profile reads a notice it does not know, with less confidence', () => {
  const r = readText(lines('Some Town\nNotice Number: AB-1234\nPlate: CCAB123\nDate: 09/23/2026\nAmount Due: $75.00'), GEN, { plates: FLEET });
  assert.equal(r.lines.length, 1);
  assert.deepEqual([r.lines[0]!.notice_number, r.lines[0]!.plate, r.lines[0]!.occurred_at, r.lines[0]!.amount_cents, r.lines[0]!.time_unknown], ['AB-1234', 'CCAB123', '2026-09-23T00:00:00', 7500, true]);
  assert.ok(r.lines[0]!.confidence < 90);
});

test('CSV: the column mapping with fees and the date order of the profile', () => {
  const rows = parseCsv('Trip,Plate,Date,Time,Toll,Fees\nT1,CCAB 123,14/09/2026,20:12,8.14,4.20\n"T2",ZZZZ999,15/09/2026,,2.00,\n');
  const out = csvLines(rows, { 0: 'notice_number', 1: 'plate', 2: 'date', 3: 'time', 4: 'amount', 5: 'fees' }, { kind: 'toll_invoice', authority: '407 ETR', dateOrder: 'dmy', plates: FLEET });
  assert.equal(out.length, 2);
  assert.deepEqual([out[0]!.plate, out[0]!.occurred_at, out[0]!.amount_cents, out[0]!.fees_cents, out[0]!.notice_number], ['CCAB123', '2026-09-14T20:12:00', 814, 420, 'T1']);
  assert.deepEqual([out[1]!.time_unknown, out[1]!.fees_cents], [true, null]);
  assert.ok(out[1]!.confidence < out[0]!.confidence);
});
