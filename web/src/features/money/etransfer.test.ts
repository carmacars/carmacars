// Release 49 (3610): Renter sent an e-Transfer (Sales) and Check e-Transfer (Finance).   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { cents, coversWords, planWords, proofKind, reportProblem, statusTone, statusWords, waitingLine, MAX_PROOF_BYTES, type EtransferPlan } from './etransfer.ts';

const fmt = (c: number) => `$${(c / 100).toFixed(2)}`;
const SQL = readFileSync(new URL('../../../../supabase/migrations/3610_r49et_etransfer_reports.sql', import.meta.url), 'utf8');

test('amounts as typed become cents; anything else is not an amount', () => {
  assert.equal(cents('1,240.50'), 124050);
  assert.equal(cents('$600'), 60000);
  assert.equal(cents(' 12.5 '), 1250);
  assert.equal(cents('12.345'), null);
  assert.equal(cents('abc'), null);
  assert.equal(cents(''), null);
  assert.equal(cents('-5'), null);
});

test('the Sales form says what is missing, in order, and sends only with a proof', () => {
  const file = { size: 2000, type: 'image/png' };
  assert.equal(reportProblem({ amount: '', covers: 'rental', file, hasDeposit: true }), 'Enter the amount the renter sent.');
  assert.equal(reportProblem({ amount: '0', covers: 'rental', file, hasDeposit: true }), 'Enter the amount the renter sent.');
  assert.match(reportProblem({ amount: '200000', covers: 'rental', file, hasDeposit: true }), /too large/);
  assert.equal(reportProblem({ amount: '100', covers: 'deposit', file, hasDeposit: false }), 'This booking has no deposit: choose the rental and fees.');
  assert.equal(reportProblem({ amount: '100', covers: 'rental', file: null, hasDeposit: true }), 'Add the screenshot or proof of the e-Transfer.');
  assert.equal(reportProblem({ amount: '100', covers: 'both', file: { size: MAX_PROOF_BYTES + 1, type: 'image/png' }, hasDeposit: true }), 'The proof must be under 10 MB.');
  assert.match(reportProblem({ amount: '100', covers: 'both', file: { size: 10, type: 'image/gif' }, hasDeposit: true }), /JPG or PNG/);
  assert.equal(reportProblem({ amount: '100', covers: 'both', file, hasDeposit: true }), '');
});

test('the proof is checked by its first bytes, not its name', () => {
  assert.deepEqual(proofKind(new Uint8Array([0xff, 0xd8, 0xff, 0xe0])), { ext: 'jpg', mime: 'image/jpeg' });
  assert.deepEqual(proofKind(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d])), { ext: 'png', mime: 'image/png' });
  assert.deepEqual(proofKind(new TextEncoder().encode('%PDF-1.7')), { ext: 'pdf', mime: 'application/pdf' });
  assert.equal(proofKind(new TextEncoder().encode('<html>')), null);
  assert.equal(proofKind(new Uint8Array([])), null);
});

test('words: what it covers, where it stands, and the line every role sees while it waits', () => {
  assert.equal(coversWords('both'), 'the rental and the deposit');
  assert.equal(statusWords('open'), 'Waiting for Finance');
  assert.equal(statusWords('declined'), 'Not received');
  assert.equal(statusTone('open'), 'ad-b--amber');
  assert.equal(waitingLine({ amount_cents: 124050, covers: 'rental', reported_by_name: 'Marco Reyes' }, fmt),
    'e-Transfer reported, waiting for Finance: $1240.50 for the rental and fees, by Marco Reyes.');
});

test('Finance sees what Confirm received records, or why it cannot', () => {
  const p: EtransferPlan = { amount_cents: 90000, covers: 'both', rental_cents: 30000, deposit_cents: 60000, rental_open_cents: 30000, deposit_owed_cents: 60000, over_cents: 0, problem: null };
  assert.equal(planWords(p, fmt), 'Confirm received records $300.00 for the rental and fees (open $300.00) and $600.00 for the deposit (owed by e-Transfer $600.00) by e-Transfer.');
  assert.match(planWords({ ...p, covers: 'rental', rental_cents: 35000, deposit_cents: 0, over_cents: 5000 }, fmt), /\$50\.00 more than is owed/);
  assert.equal(planWords({ ...p, problem: 'Nothing is open' }, fmt), 'Nothing is open');
});

test('3610: Sales never records money; only Finance or an Admin confirms, by the record_payment path', () => {
  const report = SQL.slice(SQL.indexOf('create or replace function app.etransfer_report('), SQL.indexOf('create or replace function app.etransfer_decide('));
  assert.ok(report.length > 0);
  assert.doesNotMatch(report, /insert into (payments|manual_payments|deposits)/, 'a report records no payment');
  assert.doesNotMatch(report, /record_booking_payment/);
  assert.match(report, /app\.user_va_has\(p_by, 'sales'\)/);
  assert.match(report, /b\.status <> 'pending_payment'/);
  const decide = SQL.slice(SQL.indexOf('create or replace function app.etransfer_decide('), SQL.indexOf('create or replace function app.etransfer_reports_view('));
  assert.match(decide, /if not app\.user_runs_finance\(p_by\) then raise exception/);
  assert.match(decide, /r\.reported_by = p_by and not app\.user_is_admin\(p_by\)/, 'the rep never confirms their own report');
  assert.match(decide, /app\.door\(p_by, p_aal, 'ops_do', 'record_booking_payment'/);
  assert.match(decide, /'method', 'e_transfer'/);
  assert.match(decide, /for update/);
});

test('3610: one open report per booking, audit rows, pg_temp and the server role only', () => {
  assert.match(SQL, /create unique index if not exists etransfer_reports_one_open on etransfer_reports \(booking_id\) where status = 'open'/);
  for (const a of ['etransfer_report', 'etransfer_confirm', 'etransfer_decline']) assert.match(SQL, new RegExp(`'${a}', 'etransfer_reports'`), a);
  assert.match(SQL, /create trigger audit_etransfer_reports/);
  const definers = [...SQL.matchAll(/security definer set search_path = ([^\n]+?) as \$\$/g)].map((m) => m[1]);
  assert.ok(definers.length >= 8);
  for (const d of definers) assert.match(d!, /, pg_temp$/, d);
  assert.match(SQL, /revoke all on function %s from public, anon, authenticated/);
  assert.match(SQL, /grant execute on function %s to service_role/);
  assert.match(SQL, /revoke all on etransfer_reports from public, anon, authenticated/);
  assert.doesNotMatch(SQL, /grant (insert|update|delete)[^;]*etransfer_reports to authenticated/);
});
