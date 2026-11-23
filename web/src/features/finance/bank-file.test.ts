import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { cents, csvRows, importPayload, isoDay, readBankFile, totals } from './bank-file.ts';

// Made-up account numbers and payees only (the repository is public).
const RBC = [
  '"Account Type","Account Number","Transaction Date","Cheque Number","Description 1","Description 2","CAD$","USD$"',
  'Chequing,00102-1234567,11/3/2026,,"STRIPE","PAYOUT ST-X1",1520.40,',
  'Chequing,00102-1234567,11/3/2026,,"E-TRANSFER SENT","EXAMPLE OWNER",-640.00,',
  'Chequing,00102-1234567,11/4/2026,123,"CHEQUE",,-75.5,',
  'Chequing,00102-1234567,11/4/2026,,"MONTHLY FEE",,-6.00,',
  'US Dollar,00102-7654321,11/4/2026,,"WIRE IN",,,250.00',
  ''
].join('\r\n');

describe('bank files', () => {
  it('reads amounts as cents', () => {
    assert.equal(cents('1,520.40'), 152040);
    assert.equal(cents('-75.5'), -7550);
    assert.equal(cents('(40.00)'), -4000);
    assert.equal(cents('$12'), 1200);
    assert.equal(cents('12.345'), null);
    assert.equal(cents(''), null);
    assert.equal(cents('abc'), null);
  });
  it('reads bank dates, RBC month first', () => {
    assert.equal(isoDay('11/3/2026'), '2026-11-03');
    assert.equal(isoDay('2026-11-03'), '2026-11-03');
    assert.equal(isoDay('20261103120000[-5:EST]'), '2026-11-03');
    assert.equal(isoDay('3-Nov-2026'), '2026-11-03');
    assert.equal(isoDay('Nov 3, 2026'), '2026-11-03');
    assert.equal(isoDay('13/45/2026'), null);
  });
  it('keeps quoted commas and doubled quotes', () => {
    assert.deepEqual(csvRows('a,"b, c","d ""e"""\n1,2,3'), [['a', 'b, c', 'd "e"'], ['1', '2', '3']]);
  });
  it('reads the RBC classic CSV: one account per number and currency, signed amounts', () => {
    const f = readBankFile(RBC);
    assert.equal(f.format, 'rbc_csv');
    assert.deepEqual(f.accounts.map((a) => `${a.last4}/${a.currency}/${a.lines.length}`), ['4567/CAD/4', '4321/USD/1']);
    const cad = f.accounts[0]!;
    assert.deepEqual(cad.lines[0], { posted_on: '2026-11-03', amount_cents: 152040, description: 'STRIPE PAYOUT ST-X1', cheque_number: null, fit_id: null, balance_cents: null });
    assert.equal(cad.lines[2]!.cheque_number, '123');
    assert.equal(cad.lines[2]!.amount_cents, -7550);
    assert.deepEqual(totals(cad.lines), { in_cents: 152040, out_cents: 72150, from: '2026-11-03', to: '2026-11-04', count: 4 });
  });
  it('reads a debit and credit CSV with a balance column, newest first', () => {
    const f = readBankFile('Date,Description,Debit,Credit,Balance\n2026-11-05,FEE,6.00,,9994.00\n2026-11-04,DEPOSIT,,1000.00,10000.00\n');
    assert.equal(f.format, 'csv');
    const a = f.accounts[0]!;
    assert.deepEqual(a.lines.map((l) => l.amount_cents), [-600, 100000]);
    assert.deepEqual([a.balance_cents, a.balance_on], [999400, '2026-11-05']);
    assert.equal(a.last4, null);
  });
  it('reads OFX (SGML) with FITIDs and the ledger balance', () => {
    const ofx = `OFXHEADER:100\nDATA:OFXSGML\n<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>CAD<BANKACCTFROM><BANKID>003<ACCTID>001021234567<ACCTTYPE>CHECKING</BANKACCTFROM>
<BANKTRANLIST><STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261103120000[-5:EST]<TRNAMT>1520.40<FITID>90001<NAME>STRIPE<MEMO>PAYOUT &amp; FEES</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261104<TRNAMT>-6.00<FITID>90002<NAME>MONTHLY FEE</STMTTRN></BANKTRANLIST>
<LEDGERBAL><BALAMT>10514.40<DTASOF>20261104</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`;
    const f = readBankFile(ofx);
    assert.equal(f.format, 'ofx');
    const a = f.accounts[0]!;
    assert.equal(a.last4, '4567');
    assert.deepEqual(a.lines, [
      { posted_on: '2026-11-03', amount_cents: 152040, description: 'STRIPE PAYOUT & FEES', cheque_number: null, fit_id: '90001', balance_cents: null },
      { posted_on: '2026-11-04', amount_cents: -600, description: 'MONTHLY FEE', cheque_number: null, fit_id: '90002', balance_cents: null }]);
    assert.deepEqual([a.balance_cents, a.balance_on], [1051440, '2026-11-04']);
  });
  it('refuses a file that is not a transaction download', () => {
    assert.throws(() => readBankFile('Name,Email\nA,b@example.test'), /Date and Amount/);
  });
  it('sends the last four digits and a hash, never the full account number', async () => {
    const f = readBankFile(RBC);
    const p = await importPayload(f, 0, RBC, 'rbc.csv');
    assert.ok(!JSON.stringify(p).includes('1234567'));
    assert.equal((p.account as { last4: string }).last4, '4567');
    assert.match((p.account as { hash: string }).hash, /^[0-9a-f]{64}$/);
    assert.notEqual(p.file_sha256, (await importPayload(f, 1, RBC, 'rbc.csv')).file_sha256);
    const typed = await importPayload(f, 0, RBC, 'rbc.csv', { balance_cents: 500000, balance_on: '2026-11-05' });
    assert.deepEqual([typed.balance_cents, typed.balance_source], [500000, 'typed']);
  });
});
