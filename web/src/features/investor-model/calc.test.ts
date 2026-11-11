import { test } from 'node:test';
import assert from 'node:assert/strict';
import { carPayoutSchedule, fundCar, fundCars, howItWorksRow, investmentCalc, BLANK_CAR, CAR_DEFAULTS } from './calc.ts';
import { myInvestment } from './mine.ts';
import type { Investment, ReturnRow } from '../investor/plan.ts';

// The workbook (CarmaCars_Investor_Model.xlsx, "Investment calculator"): CA$50,000 from November 15, 2026 at 30%,
// 6-month lockup, paid out.
const W = { amount: 50_000, start: '2026-11-15', rate: 0.3, lockupMonths: 6, reinvest: false };
const near = (a: number, b: number, msg?: string) => assert.ok(Math.abs(a - b) < 1e-6, `${msg ?? ''} got ${a}, want ${b}`);

test('$50,000 at 30% pays $1,250 a month from month 7; nothing in months 1 to 6', () => {
  const r = investmentCalc(W);
  assert.equal(r.rows.length, 36);
  for (const row of r.rows.slice(0, 6)) { assert.equal(row.phase, 'Lockup'); assert.equal(row.paid, 0); }
  for (const row of r.rows.slice(6)) { assert.equal(row.phase, 'Earning'); near(row.paid, 1250); }
  near(r.monthlyPayout, 1250); near(r.monthlyReturn, 1250); near(r.yearlyReturn, 15_000);
  assert.equal(r.lockupEnds, '2027-05-15');
  assert.equal(r.firstPayment, '2027-06-15');
  assert.equal(r.rows[6]!.date, '2027-06-15'); // month 7: EDATE(start, 7)
  near(r.paidBy24, 1250 * 18, 'paid by month 24');
  near(r.paidBy36, 1250 * 30, 'paid by month 36');
  near(r.balance36, 50_000); near(r.value36, 87_500); near(r.multiple36, 1.75);
  assert.equal(r.belowMinimum, false);
});

test('reinvested: nothing paid out, the balance compounds monthly from month 7', () => {
  const r = investmentCalc({ ...W, reinvest: true });
  near(r.monthlyPayout, 0); near(r.paidBy36, 0);
  near(r.rows[6]!.earned, 1250); near(r.rows[6]!.balanceEnd, 51_250);
  near(r.rows[7]!.earned, 51_250 * 0.025); // month 8 earns on the larger balance
  near(r.balance36, 50_000 * 1.025 ** 30);
  near(r.earnedBy36, r.balance36 - 50_000);
});

test('below the $20,000 minimum is flagged; month ends clamp like EDATE', () => {
  assert.equal(investmentCalc({ ...W, amount: 19_999 }).belowMinimum, true);
  const r = investmentCalc({ ...W, start: '2027-01-31' });
  assert.equal(r.rows[0]!.date, '2027-02-28');
  assert.equal(r.lockupEnds, '2027-07-31');
});

test('How it works examples: $20,000 at 30% is $500 a month, $9,000 by month 24, $15,000 by month 36', () => {
  const x = howItWorksRow(20_000, 0.3);
  near(x.monthly, 500); near(x.yearly, 6000); near(x.by24, 9000); near(x.by36, 15_000);
});

test('Fund a car: the deck example ($7,000 car, $80 a rented day, 25 days, 70%) pays $1,400 a month before the fees of the agreement', () => {
  const c = fundCar(CAR_DEFAULTS);
  near(c.gross, 2000); near(c.company, 600); near(c.ownerShare, 1400); near(c.cash, 1400);
  near(c.depreciation, 87.5); near(c.net, 1312.5); near(c.yearlyCash, 16_800); near(c.yearlyNet, 15_750);
  near(c.roi, 15_750 / 7000); near(c.paybackMonths ?? 0, 7000 / 1400); near(c.upfront, 0);
  const all = fundCars([CAR_DEFAULTS, BLANK_CAR, BLANK_CAR]);
  near(all.total.cash, 1400); near(all.total.roi, 15_750 / 7000);
  const s = carPayoutSchedule('2026-12-01', 1400);
  assert.equal(s[0]!.paidOn, '2027-01-10'); near(s[11]!.cumulative, 16_800);
  // with the agreement's monthly fees entered, they come off the payout
  near(fundCar({ ...CAR_DEFAULTS, insuranceFee: 100, trackerFee: 20 }).cash, 1280);
});

test('commissions come off before the split', () => {
  const c = fundCar({ ...CAR_DEFAULTS, commissions: 0.1 });
  near(c.commissions, 200); near(c.company, 540); near(c.ownerShare, 1260);
});

// "My investment": records first, then the agreement's formula
const inv: Investment = { id: 'a', principal_cents: 5_000_000, reinvested_cents: 0, redeemed_cents: 0, invested_amount_cents: 5_000_000, yearly_bps: 3000,
  investment_date: '2026-03-01', lockup_end_date: '2026-09-01', status: 'active', mode: 'pay', next_payment_date: '2026-11-15' };
const rec = (m: string, status: string, disposition = 'pay'): ReturnRow => ({ id: m, return_month: `${m}-01`, opening_invested_cents: 5_000_000, days_earning: 30, days_in_month: 30,
  return_cents: 125_000, disposition, payment_date: `${m.slice(0, 5)}${String(Number(m.slice(5)) + 1).padStart(2, '0')}-15`, status });

test('my investment: a recorded payout counts as paid, the next one is on record, then $1,250 projected each month', () => {
  const s = myInvestment([inv], [rec('2026-09', 'paid'), rec('2026-10', 'accrued')], '2026-11-01');
  assert.equal(s.payoutsMadeCents, 125_000);
  assert.equal(s.payoutsMadeCount, 1);
  assert.deepEqual(s.next, { date: '2026-11-15', cents: 125_000, estimated: false, mode: 'pay' });
  assert.equal(s.rows.length, 36);
  assert.equal(s.rows[0]!.state, 'paid');
  assert.equal(s.rows[1]!.state, 'to_be_paid');
  assert.equal(s.rows[2]!.state, 'projected');
  assert.equal(s.rows[2]!.returnCents, 125_000);
  assert.equal(s.rows[2]!.date, '2026-12-15');
  assert.equal(s.lockupEnd, '2026-09-01');
  assert.equal(s.yearlyBps, 3000);
});

test('my investment: recording the next payout moves it to paid (live), and the reinvest toggle compounds the projection', () => {
  const after = myInvestment([inv], [rec('2026-09', 'paid'), rec('2026-10', 'paid')], '2026-11-20');
  assert.equal(after.payoutsMadeCents, 250_000);
  assert.equal(after.rows[1]!.state, 'paid');
  assert.equal(after.next?.estimated, true);
  assert.equal(after.next?.date, '2026-12-15');
  const re = myInvestment([inv], [rec('2026-09', 'paid'), rec('2026-10', 'paid')], '2026-11-20', { reinvest: true });
  assert.equal(re.rows[2]!.mode, 'reinvest');
  assert.equal(re.rows[2]!.returnCents, 125_000);
  assert.equal(re.rows[3]!.returnCents, Math.round(5_125_000 * 0.025));
  assert.equal(re.projectedPaidCents, 0);
});

test('my investment: inside the lockup the first Return Month is a part month by days, nothing recorded yet', () => {
  const x = { ...inv, investment_date: '2026-10-16', lockup_end_date: '2027-04-16', next_payment_date: '2027-05-15' };
  const s = myInvestment([x], [], '2026-11-01');
  assert.equal(s.rows[0]!.month, '2027-04-01');
  assert.equal(s.rows[0]!.returnCents, Math.round((5_000_000 * 3000 * 15) / (120000 * 30)));
  assert.equal(s.next?.date, '2027-05-15');
  assert.equal(s.payoutsMadeCount, 0);
});
