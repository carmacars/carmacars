// "My investment": the investor's own sheet, live from their records (investments and investment_returns through
// investor_read home and statements; migration 0010's accrual and 0031's door). Months already accrued come from the
// records as they are (paid, to be paid, on hold, reinvested); the months after are projected with the agreement's own
// formula (public.calc_investment_return, features/deck/returns.ts), paid or reinvested as the investor chooses on the
// page. A payout recorded in the database moves a row from "projected" to "paid" on the next view: nothing is stored here.
import { addMonths, daysInMonth, monthlyReturnCents } from '../deck/returns.ts';
import type { Investment, ReturnRow } from '../investor/plan.ts';

export type RowState = 'paid' | 'to_be_paid' | 'held' | 'reinvested' | 'projected';
export interface MineRow { month: string; date: string; openingCents: number; returnCents: number; mode: 'pay' | 'reinvest'; state: RowState; recorded: boolean; lockup: boolean }
export interface MineSummary {
  investedCents: number; principalCents: number; startDate: string | null; yearlyBps: number | null; lockupEnd: string | null;
  payoutsMadeCents: number; payoutsMadeCount: number; reinvestedCents: number;
  next: { date: string; cents: number; estimated: boolean; mode: 'pay' | 'reinvest' } | null;
  rows: MineRow[]; projectedPaidCents: number; projectedReinvestedCents: number; reinvest: boolean; election: 'pay' | 'reinvest';
}

const ym = (s: string) => s.slice(0, 7);
const first = (key: string) => `${key}-01`;
const nextKey = (key: string, n = 1) => ym(addMonths(first(key), n));

/** The Return of one investment for a month, as the agreement computes it, on a given Invested Amount (0 in the lockup). */
function monthReturn(x: Investment, key: string, investedCents: number): number {
  const [y, m] = [Number(key.slice(0, 4)), Number(key.slice(5, 7))];
  const dim = daysInMonth(y, m);
  if (x.status !== 'active' || `${key}-${String(dim).padStart(2, '0')}` < x.lockup_end_date) return 0;
  const from = x.lockup_end_date > first(key) ? Number(x.lockup_end_date.slice(8, 10)) : 1;
  return monthlyReturnCents(investedCents, x.yearly_bps, dim - from + 1, dim);
}

export function myInvestment(investments: Investment[], rows: ReturnRow[], today: string, opts: { reinvest?: boolean; payDay?: number; months?: number } = {}): MineSummary {
  const payDay = opts.payDay ?? 15;
  const span = opts.months ?? 36;
  const active = investments.filter((x) => x.status === 'active');
  const election: 'pay' | 'reinvest' = active.length > 0 && active.every((x) => x.mode === 'reinvest') ? 'reinvest' : 'pay';
  const reinvest = opts.reinvest ?? election === 'reinvest';
  const asc = [...rows].sort((a, b) => a.return_month.localeCompare(b.return_month));
  const paid = asc.filter((r) => r.status === 'paid');
  const startDate = [...investments].map((x) => x.investment_date).sort()[0] ?? null;
  const lockupEnd = active.map((x) => x.lockup_end_date).sort()[0] ?? null;
  const bps = active.length ? Math.round(active.reduce((s, x) => s + x.yearly_bps * x.invested_amount_cents, 0) / Math.max(1, active.reduce((s, x) => s + x.invested_amount_cents, 0))) : null;
  const payDate = (key: string) => { const k = nextKey(key); const dim = daysInMonth(Number(k.slice(0, 4)), Number(k.slice(5, 7))); return `${k}-${String(Math.min(payDay, dim)).padStart(2, '0')}`; };
  const monthEnd = (key: string) => `${key}-${String(daysInMonth(Number(key.slice(0, 4)), Number(key.slice(5, 7)))).padStart(2, '0')}`;

  // the window: 36 Return Months from the first one (the month the earliest lockup ends), or from a year ago for an older investment
  const firstReturn = lockupEnd ? ym(lockupEnd) : null;
  const yearAgo = nextKey(ym(today), -11);
  const startKey = firstReturn ? (firstReturn < yearAgo ? yearAgo : firstReturn) : null;
  const out: MineRow[] = [];
  if (startKey && active.length) {
    // recorded months by month; each investment's Invested Amount carried forward from its records (or today's amount)
    const byMonth = new Map<string, ReturnRow[]>();
    for (const r of asc) byMonth.set(ym(r.return_month), [...(byMonth.get(ym(r.return_month)) ?? []), r]);
    const lastRecorded = asc.length ? ym(asc[asc.length - 1]!.return_month) : null;
    const invested = new Map(active.map((x) => [x.id, x.invested_amount_cents]));
    for (let k = 0, key = startKey; k < span; k++, key = nextKey(key)) {
      const rec = byMonth.get(key);
      if (rec && rec.length) {
        const cents = rec.reduce((s, r) => s + r.return_cents, 0);
        const st: RowState = rec.every((r) => r.status === 'paid') ? 'paid' : rec.some((r) => r.status === 'held') ? 'held'
          : rec.every((r) => r.disposition === 'reinvest' || r.status === 'reinvested') ? 'reinvested' : 'to_be_paid';
        const mode = rec.every((r) => r.disposition === 'reinvest') ? 'reinvest' : 'pay';
        out.push({ month: first(key), date: mode === 'reinvest' ? monthEnd(key) : rec[0]!.payment_date, openingCents: rec.reduce((s, r) => s + r.opening_invested_cents, 0),
          returnCents: cents, mode, state: st, recorded: true, lockup: false });
        continue;
      }
      if (lastRecorded && key <= lastRecorded) continue; // a month with no Return on record before the last one: nothing earned
      const mode: 'pay' | 'reinvest' = reinvest ? 'reinvest' : 'pay';
      let cents = 0, opening = 0, lock = true;
      for (const x of active) {
        const inv = invested.get(x.id) ?? x.invested_amount_cents;
        opening += inv;
        const ret = monthReturn(x, key, inv);
        if (monthEnd(key) >= x.lockup_end_date) lock = false;
        cents += ret;
        if (mode === 'reinvest') invested.set(x.id, inv + ret);
      }
      out.push({ month: first(key), date: mode === 'reinvest' ? monthEnd(key) : payDate(key), openingCents: opening, returnCents: cents, mode, state: 'projected', recorded: false, lockup: lock });
    }
  }
  // the next payout: a Return on record not paid yet, else the first projected month with something in it
  const open = out.find((r) => r.recorded && r.state === 'to_be_paid' && r.date >= today);
  const proj = out.find((r) => !r.recorded && r.returnCents > 0);
  const next = open ? { date: open.date, cents: open.returnCents, estimated: false, mode: open.mode } : proj ? { date: proj.date, cents: proj.returnCents, estimated: true, mode: proj.mode } : null;
  return {
    investedCents: active.reduce((s, x) => s + x.invested_amount_cents, 0),
    principalCents: active.reduce((s, x) => s + x.principal_cents, 0),
    startDate, yearlyBps: bps, lockupEnd,
    payoutsMadeCents: paid.reduce((s, r) => s + r.return_cents, 0), payoutsMadeCount: paid.length,
    reinvestedCents: asc.filter((r) => r.status === 'reinvested').reduce((s, r) => s + r.return_cents, 0),
    next, rows: out,
    projectedPaidCents: out.filter((r) => !r.recorded && r.mode === 'pay').reduce((s, r) => s + r.returnCents, 0),
    projectedReinvestedCents: out.filter((r) => !r.recorded && r.mode === 'reinvest').reduce((s, r) => s + r.returnCents, 0),
    reinvest, election
  };
}
