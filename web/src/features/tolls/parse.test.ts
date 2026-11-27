import { test } from 'node:test';
import assert from 'node:assert/strict';
import { autoMap, classifyHeader, csvLines, findDate, findPlate, findTime, headerRow, moneyTokens, parseCsv, pickProfile, readText, type Cell, type Profile, type TextLine } from './parse.ts';

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

test('CSV: the column mapping with fees and the date order of the profile; the amount is the charge plus its fees (5140)', () => {
  const rows = parseCsv('Trip,Plate,Date,Time,Toll,Fees\nT1,CCAB 123,14/09/2026,20:12,8.14,4.20\n"T2",ZZZZ999,15/09/2026,,2.00,\n');
  const { lines: out } = csvLines(rows, { 0: 'notice_number', 1: 'plate', 2: 'date', 3: 'time', 4: 'amount', 5: 'fees' }, { kind: 'toll_invoice', authority: '407 ETR', dateOrder: 'dmy', plates: FLEET });
  assert.equal(out.length, 2);
  assert.deepEqual([out[0]!.plate, out[0]!.occurred_at, out[0]!.amount_cents, out[0]!.fees_cents, out[0]!.notice_number], ['CCAB123', '2026-09-14T20:12:00', 1234, 420, 'T1']);
  assert.deepEqual([out[1]!.time_unknown, out[1]!.fees_cents, out[1]!.amount_cents], [true, null, 200]);
  assert.ok(out[1]!.confidence < out[0]!.confidence);
});

// ---------------------------------------------------------------- 5140: 407 ETR statements as the files are shaped
// The layouts of a 407 ETR account statement: the PDF (account details, then trips grouped under each licence plate, a
// column table repeated at the top of each page, a distance printed without "km", a camera charge and a trip toll charge
// beside the toll, a total column, entry and exit names on two lines, the monthly account fee apart) and the CSV download
// (account details above the header row, plates with the province, 12-hour times with seconds, a payment row). Plates,
// account and statement numbers are made up.

/** A line laid out in columns, as pdf.js gives it: each value at the left edge of its column (fractions of the page). */
const X = [0.04, 0.12, 0.2, 0.34, 0.42, 0.56, 0.64, 0.73, 0.82, 0.91];
const row = (vals: Array<string | null>, page = 1, y = 0): TextLine => {
  const cells: Cell[] = vals.map((t, i) => (t ? { text: t, x0: X[i]!, x1: X[i]! + Math.min(0.075, t.length * 0.009) } : null)).filter((c): c is Cell => !!c);
  return { text: cells.map((c) => c.text).join('  '), page, y, h: 0.02, cells };
};
const text = (t: string, page = 1, y = 0): TextLine => ({ text: t, page, y, h: 0.02, cells: [{ text: t, x0: 0.04, x1: 0.04 + t.length * 0.008 }] });
const HEAD = ['Date', 'Entry Time', 'Entry', 'Exit Time', 'Exit', 'Distance', 'Toll Charge', 'Camera Charge', 'Trip Toll Charge', 'Total'];
const P407_5140: Profile = { ...P407, rules: { ...P407.rules, fields: { ...P407.rules.fields, plate: ['Licence Plate', 'Plate'] }, trip: { ...P407.rules.trip, statement_fee_words: ['Account Fee', 'Late Payment', 'Statement Fee'] } } };
const PDF407: TextLine[] = [
  text('407 ETR Express Toll Route', 1, 0.02), text('Statement Number: ST-0000000001', 1, 0.05), text('Statement Date: Nov 18, 2026', 1, 0.07),
  text('Account Number: 200000000000', 1, 0.09), text('Payment Due Date: Dec 8, 2026', 1, 0.11), text('Total Amount Due $81.63', 1, 0.13), text('Previous Balance $0.00', 1, 0.15),
  text('Licence Plate: CCAB 123', 1, 0.2), row(HEAD, 1, 0.22),
  row(['Nov 03', '08:15 AM', 'Hwy 427', '08:41 AM', 'Brock Rd', '54.21', '$21.33', '$4.25', '$1.00', '$26.58'], 1, 0.25),
  row(['Nov 03', '6:02 PM', 'Brock Rd', '6:30 PM', 'Highway', '54.21', '$23.10', '$4.25', '$1.00', '$28.35'], 1, 0.28),
  row([null, null, null, null, '427'], 1, 0.3),
  text('Page 1 of 2', 1, 0.97),
  row(HEAD, 2, 0.05),
  text('Licence Plate: TXYZ 789', 2, 0.08),
  row(['Dec 30', '11:59 PM', 'Yonge St', '12:20 AM', 'Hwy 400', '9.87', '$3.20', '$4.25', '$1.00', '$8.45'], 2, 0.1),
  row(['Nov 14', '13:05', 'Dixie Rd', '13:22', 'Hwy 410', '12.00', '$9.00', '$0.00', '$1.00', '$10.00'], 2, 0.13),
  text('Total Trip Charges $73.38', 2, 0.2), text('Monthly Account Fee $4.25', 2, 0.22), text('Late Payment Charge $4.00', 2, 0.24)
];

test('407 PDF: each trip read by its columns: date and entry time, plate from its heading, entry and exit, the toll with its camera and trip charges, not the distance', () => {
  const r = readText(PDF407, P407_5140, { plates: FLEET });
  assert.equal(r.layout, 'statement');
  assert.deepEqual([r.statement_number, r.statement_date, r.due_on, r.total_cents], ['ST-0000000001', '2026-11-18', '2026-12-08', 8163]);
  assert.equal(r.lines.length, 4);
  const [a, b, c, d] = r.lines;
  assert.deepEqual([a!.occurred_at, a!.plate, a!.entry, a!.exit, a!.amount_cents, a!.fees_cents, a!.time_unknown], ['2026-11-03T08:15:00', 'CCAB123', 'Hwy 427', 'Brock Rd', 2658, 525, false]);
  assert.deepEqual([b!.occurred_at, b!.exit, b!.amount_cents], ['2026-11-03T18:02:00', 'Highway 427', 2835], 'a place on two lines is one place');
  assert.deepEqual([c!.plate, c!.occurred_at, c!.amount_cents, c!.fees_cents], ['TXYZ789', '2025-12-30T23:59:00', 845, 525], 'a later plate heading, on the next page; December on a November statement is last year');
  assert.deepEqual([d!.plate, d!.occurred_at, d!.amount_cents, d!.fees_cents], ['TXYZ789', '2026-11-14T13:05:00', 1000, 100]);
  for (const l of r.lines) assert.ok(l.confidence >= 90, `confidence ${l.confidence}: ${l.source_text}`);
  assert.deepEqual(r.statement_fees.map((f) => f.amount_cents), [425, 400]);
  assert.deepEqual(r.problems, [], 'the lines and the fees add up to the amount due');
});

test('407 PDF: a header printed on two lines, a credit left out and said, a line whose charges do not add up flagged', () => {
  const two = [text('407 ETR', 1, 0.01), text('Statement Date: 2026-11-18', 1, 0.02),
    row(['Trip', 'Entry', 'Entry', 'Exit', 'Exit', 'Distance', 'Toll', 'Video Toll', 'Trip Toll', 'Total'], 1, 0.1),
    row(['Date', 'Time', 'Interchange', 'Time', 'Interchange', '(km)', 'Charge', 'Charge', 'Charge', null], 1, 0.12),
    row(['2026-11-05', '07:40', 'Hwy 401', '07:58', 'Hwy 403', '20.00', '$7.00', '$4.25', '$1.00', '$12.25'], 1, 0.15),
    row(['2026-11-06', '07:40', 'Hwy 401', '07:58', 'Hwy 403', '20.00', '$7.00', '$4.25', '$1.00', '$15.00'], 1, 0.17),
    row(['2026-11-07', null, 'Reversal', null, null, null, '-$7.00', null, null, '-$7.00'], 1, 0.19)];
  const r = readText(two, P407_5140, { plates: FLEET });
  assert.equal(r.lines.length, 2);
  assert.deepEqual([r.lines[0]!.occurred_at, r.lines[0]!.entry, r.lines[0]!.amount_cents, r.lines[0]!.fees_cents], ['2026-11-05T07:40:00', 'Hwy 401', 1225, 525]);
  assert.ok(r.lines[1]!.confidence < 80, 'a total that is not its charges is checked by a person');
  assert.match(r.problems.join(' | '), /credit or reversal was left out/);
  assert.match(r.problems.join(' | '), /add up to 12\.25, its total says 15\.00/);
});

test('407 headers: each column name is read for what it is', () => {
  assert.deepEqual(['Trip Date', 'Entry Time', 'Exit Time', 'Entry Interchange', 'Exit Interchange', 'Licence Plate', 'Distance (km)', 'Toll Charge', 'Video Toll Charge', 'Trip Toll Charge', 'Camera Charge', 'Total Charges', 'Transponder', 'Trip ID', 'Vehicle Class'].map(classifyHeader),
    ['date', 'time', 'skip', 'entry', 'exit', 'plate', 'distance', 'toll', 'fee', 'fee', 'fee', 'total', 'transponder', 'ref', 'skip']);
});

const CSV407 = `Account Number,200000000000
Statement Date,2026-11-18
Statement Number,ST-0000000001

Trip Date,Entry Time,Entry Interchange,Exit Time,Exit Interchange,Licence Plate,Distance (km),Toll Charge,Video Toll Charge,Trip Toll Charge,Total Charges
11/03/2026,8:15:22 AM,Hwy 427,8:41:10 AM,Brock Rd,CCAB123 ON,54.21,$21.33,$4.25,$1.00,$26.58
11/14/2026,1:05:00 PM,Dixie Rd,1:22:00 PM,Hwy 410,TXYZ 789 (ON),12.00,$9.00,$0.00,$1.00,$10.00
11/16/2026,,Payment - Thank you,,,,,"($50.00)",,,"($50.00)"
,,,,,,,,,Total,$36.58
`;

test('407 CSV: the header found under the account details, every column mapped, fees summed, plates with the province, 12-hour times with seconds', () => {
  const rows = parseCsv(CSV407);
  const h = headerRow(rows);
  assert.equal(h, 3, 'the blank line is not a row');
  const map = autoMap(rows[h]!);
  assert.deepEqual(map, { 0: 'date', 1: 'time', 2: 'entry', 4: 'exit', 5: 'plate', 7: 'amount', 8: 'fees', 9: 'fees', 10: 'total' });
  const { lines, problems } = csvLines(rows, map, { kind: 'toll_invoice', authority: '407 ETR', plates: FLEET, header: h });
  assert.equal(lines.length, 2);
  assert.deepEqual([lines[0]!.plate, lines[0]!.occurred_at, lines[0]!.entry, lines[0]!.exit, lines[0]!.amount_cents, lines[0]!.fees_cents], ['CCAB123', '2026-11-03T08:15:00', 'Hwy 427', 'Brock Rd', 2658, 525]);
  assert.deepEqual([lines[1]!.plate, lines[1]!.occurred_at, lines[1]!.amount_cents, lines[1]!.fees_cents], ['TXYZ789', '2026-11-14T13:05:00', 1000, 100]);
  assert.ok(lines.every((l) => l.confidence >= 90), 'month first is known from 11/14/2026, so 11/03/2026 is not ambiguous');
  assert.match(problems.join(' '), /credit or reversal was left out/);
});
