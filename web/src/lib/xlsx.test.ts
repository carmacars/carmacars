import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Workbook, colLetter, colIndex, serial, FMT } from './xlsx.ts';
import { investorWorkbook } from '../features/investor-model/workbook.ts';
import { myInvestment } from '../features/investor-model/mine.ts';
import { internalWorkbook, INTERNAL } from '../features/finance-model/workbook.ts';
import { DEFAULT_INPUTS, runModel, type ActualMonth } from '../features/finance-model/engine.ts';

// Read back the stored (uncompressed) ZIP the writer makes: file name to text.
function unzip(b: Uint8Array): Map<string, string> {
  const out = new Map<string, string>(); const dv = new DataView(b.buffer, b.byteOffset, b.byteLength); const dec = new TextDecoder();
  let p = 0;
  while (dv.getUint32(p, true) === 0x04034b50) {
    const size = dv.getUint32(p + 18, true), nlen = dv.getUint16(p + 26, true), xlen = dv.getUint16(p + 28, true);
    const name = dec.decode(b.subarray(p + 30, p + 30 + nlen));
    out.set(name, dec.decode(b.subarray(p + 30 + nlen + xlen, p + 30 + nlen + xlen + size)));
    p += 30 + nlen + xlen + size;
  }
  return out;
}

test('columns, dates and the package parts', () => {
  assert.equal(colLetter(1), 'A'); assert.equal(colLetter(26), 'Z'); assert.equal(colLetter(62), 'BJ'); assert.equal(colIndex('BJ'), 62);
  assert.equal(serial('1900-03-01'), 61); assert.equal(serial('2026-11-15'), 46341);
  const wb = new Workbook('T');
  wb.sheet('One').put('A1', 'R&D <x>').put('B1', 3).put('C1', '=B1*2', { fmt: FMT.CUR }).put('D1', { date: '2026-11-15' }, { fmt: FMT.DATE }).merge('A2:B2');
  const f = unzip(wb.bytes(new Date('2026-11-01T12:00:00Z')));
  for (const part of ['[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/styles.xml', 'xl/worksheets/sheet1.xml', 'docProps/core.xml']) assert.ok(f.has(part), part);
  const s = f.get('xl/worksheets/sheet1.xml')!;
  assert.match(s, /<t xml:space="preserve">R&amp;D &lt;x&gt;<\/t>/);
  assert.match(s, /<c r="C1" s="\d+"><f>B1\*2<\/f><\/c>/);
  assert.match(s, /<c r="D1" s="\d+"><v>46341<\/v><\/c>/);
  assert.match(s, /<mergeCell ref="A2:B2"\/>/);
  assert.match(f.get('xl/workbook.xml')!, /fullCalcOnLoad="1"/);
  assert.match(f.get('xl/styles.xml')!, /formatCode="&quot;CA\$&quot;#,##0/);
  assert.throws(() => wb.sheet('Bad/name'));
});

test('the investor workbook: the safe tabs only, the calculator formulas of the model workbook, their own records', () => {
  const inv = { id: 'a', principal_cents: 5_000_000, reinvested_cents: 0, redeemed_cents: 0, invested_amount_cents: 5_000_000, yearly_bps: 3000, investment_date: '2026-03-01',
    lockup_end_date: '2026-09-01', status: 'active', mode: 'pay', next_payment_date: '2026-11-15' };
  const mine = myInvestment([inv], [], '2026-11-01');
  const f = unzip(investorWorkbook({ multiplier: 3.2, rate: 0.3, minimum: 20000, lockupMonths: 6, amount: 50000, start: '2026-11-15', reinvest: false, investorName: 'Dana Example',
    company: 'Example Holdings Inc.', mine, generatedOn: '2026-11-01' }).bytes());
  const book = f.get('xl/workbook.xml')!;
  assert.deepEqual([...book.matchAll(/<sheet name="([^"]+)"/g)].map((m) => m[1]), ['Read me', 'My investment', 'How it works (summary)', 'Investment calculator', 'Fund a car (owner program)']);
  const all = [...f.entries()].filter(([k]) => k.startsWith('xl/worksheets/')).map(([, v]) => v).join('\n');
  // never a fleet fact: no internal tab, no utilization, fleet size, insurance premium or company costs
  for (const word of ['DO NOT SHARE', 'tilization', 'premium', 'EBITDA', 'Actuals', 'Cars on the fleet', 'Company P&amp;L']) assert.ok(!all.includes(word), word);
  const calc = f.get('xl/worksheets/sheet4.xml')!;
  assert.match(calc, /<c r="B14" s="\d+"><f>IF\(B10=&quot;Yes&quot;,0,B6\*B8\/12\)<\/f><\/c>/);
  assert.match(calc, /<c r="E34" s="\d+"><f>IF\(A34&lt;=\$B\$9,0,D34\*\$B\$8\/12\)<\/f><\/c>/);
  assert.match(calc, /<c r="B6" s="\d+"><v>50000<\/v><\/c>/);
  assert.match(f.get('xl/worksheets/sheet3.xml')!, /3\.2x/);
});

test('the internal workbook: every internal tab marked DO NOT SHARE, actuals as values, the forecast as formulas', () => {
  const oct: ActualMonth = { month: '2026-10-01', complete: true, rental_cents: 1_194_100, rental_insurer_cents: 755_300, rental_renter_cents: 438_800, rented_days: 106.2, rentals: 14, cars: 20,
    fees_cents: 0, fees_by_kind: {}, cash_by_method: {}, owner_share_cents: 600_000, partner_share_cents: 0, commissions_cents: 0, kickbacks_cents: 0, owner_payouts_paid_cents: 0,
    processing_cents: 0, expenses_cents: 0, expenses_by_category: {}, investor_payouts_cents: 0, investor_capital_cents: 0 };
  const model = runModel([oct], DEFAULT_INPUTS);
  const f = unzip(internalWorkbook({ actuals: [oct], inputs: DEFAULT_INPUTS, investors: [], model, multiplier: 3.2, offerRate: 0.3, minimum: 20000, lockupMonths: 6, company: null,
    generatedOn: '2026-11-01', computedAt: null }).bytes());
  const names = [...f.get('xl/workbook.xml')!.matchAll(/<sheet name="([^"]+)"/g)].map((m) => m[1]!);
  assert.deepEqual(names.slice(4), [INTERNAL.a, INTERNAL.act, INTERNAL.f, INTERNAL.pf]);
  const act = f.get('xl/worksheets/sheet6.xml')!, fc = f.get('xl/worksheets/sheet7.xml')!;
  assert.match(act, /<v>11941<\/v>/);
  assert.match(fc, /<c r="C5" [^>]*><f>IF\(AND\('Actuals - DO NOT SHARE'!C\$5=1,C\$3&lt;=\$B\$9\),&quot;A&quot;,&quot;F&quot;\)<\/f><\/c>/);
  assert.match(fc, /<c r="BJ3"/); // 60 months, C to BJ
});
