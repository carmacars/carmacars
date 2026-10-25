// The investor home's figures, from the investor's own records only (investor_read home and statements, migration 0031):
// what they invested, what was paid or reinvested, the next payment, the schedule and their account month by month.
// An amount not on a statement yet is estimated with the agreement's formula (features/deck/returns.ts, the same as
// public.calc_investment_return) and always labelled as an estimate. Display only: nothing here accrues or pays.
import { daysInMonth, monthlyReturnCents } from '../deck/returns.ts';

export interface Investment { id: string; principal_cents: number; reinvested_cents: number; redeemed_cents: number; invested_amount_cents: number; yearly_bps: number;
  investment_date: string; lockup_end_date: string; status: string; mode: string; next_payment_date: string; is_initial?: boolean }
export interface InvestorHome { investor: { legal_name: string; status: string; tax_information_complete: boolean }; agreement: { agreement_number: string } | null;
  investments: Investment[];
  latest: { id: string; return_month: string; return_cents: number; disposition: string; status: string } | null;
  redemptions: Array<{ notice_date: string; redemption_date: string; amount_cents: number; status: string }>; held: Array<{ return_month: string; return_cents: number; hold_reason: string | null }>;
  requests: Array<{ title: string; status: string; created_at: string }> }
export interface ReturnRow { id: string; return_month: string; opening_invested_cents: number; days_earning: number; days_in_month: number; return_cents: number; disposition: string; payment_date: string; status: string }

export interface ScheduleItem { key: string; date: string; title: string; cents: number; note: string; state: 'done' | 'now' | 'future'; estimated: boolean }
export interface Plan {
  investedCents: number; paidCents: number; reinvestedCents: number; earnedCents: number;
  next: { date: string; cents: number; estimated: boolean } | null;
  schedule: ScheduleItem[];
  chart: { labels: string[]; invested: Array<number | null>; returns: Array<number | null>; projected: Array<number | null> };
}

const ym = (s: string) => s.slice(0, 7);
const addMonth = (key: string, n: number) => { const i = Number(key.slice(0, 4)) * 12 + Number(key.slice(5, 7)) - 1 + n; return `${Math.floor(i / 12)}-${String((i % 12) + 1).padStart(2, '0')}`; };
const short = (key: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', year: '2-digit', timeZone: 'UTC' }).format(new Date(`${key}-15T12:00:00Z`)).replace('.', '');
const long = (key: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${key}-15T12:00:00Z`));

/** The Return of one investment for one Return Month, estimated as the agreement computes it (0 inside the lockup). */
export function estimateMonth(x: Investment, key: string): number {
  const [y, m] = [Number(key.slice(0, 4)), Number(key.slice(5, 7))];
  const dim = daysInMonth(y, m);
  const end = `${key}-${String(dim).padStart(2, '0')}`;
  if (x.status !== 'active' || end < x.lockup_end_date) return 0;
  const first = x.lockup_end_date > `${key}-01` ? Number(x.lockup_end_date.slice(8, 10)) : 1;
  return monthlyReturnCents(x.invested_amount_cents, x.yearly_bps, dim - first + 1, dim);
}

export function investorPlan(h: Pick<InvestorHome, 'investments'>, rows: ReturnRow[], today: string, ahead = 3): Plan {
  const active = h.investments.filter((x) => x.status === 'active');
  const asc = [...rows].sort((a, b) => a.return_month.localeCompare(b.return_month));
  const investedCents = active.reduce((s, x) => s + x.invested_amount_cents, 0);
  const paidCents = rows.filter((r) => r.status === 'paid').reduce((s, r) => s + r.return_cents, 0);
  const reinvestedCents = rows.filter((r) => r.status === 'reinvested').reduce((s, r) => s + r.return_cents, 0);
  const earnedCents = rows.reduce((s, r) => s + r.return_cents, 0);
  // the next payment: a Return on a statement not paid yet, else the next Payment Date with its estimated amount
  const open = asc.filter((r) => r.status === 'accrued' && r.payment_date >= today);
  const byDate = new Map<string, number>();
  for (const r of open) byDate.set(r.payment_date, (byDate.get(r.payment_date) ?? 0) + r.return_cents);
  const firstOpen = [...byDate.keys()].sort()[0];
  const lastMonth = asc.length ? ym(asc[asc.length - 1]!.return_month) : null;
  const nextDate = active.map((x) => x.next_payment_date).sort()[0];
  const estimateFor = (key: string) => active.reduce((s, x) => s + estimateMonth(x, key), 0);
  const payDay = (key: string) => { const d = nextDate ? Number(nextDate.slice(8, 10)) : 15; const k = addMonth(key, 1); return `${k}-${String(d).padStart(2, '0')}`; };
  let next: Plan['next'] = null;
  if (firstOpen) next = { date: firstOpen, cents: byDate.get(firstOpen)!, estimated: false };
  else if (nextDate) {
    const key = addMonth(ym(nextDate), -1);
    const cents = estimateFor(key);
    if (cents > 0) next = { date: nextDate, cents, estimated: true };
  }
  // the schedule: the last three on statements, the open ones, then the next months estimated
  const reinvest = active.length > 0 && active.every((x) => x.mode === 'reinvest');
  const schedule: ScheduleItem[] = [];
  for (const r of asc.slice(-4)) {
    const done = r.status === 'paid' || r.status === 'reinvested';
    schedule.push({ key: r.id, date: r.disposition === 'reinvest' ? `${ym(r.return_month)}-${String(r.days_in_month).padStart(2, '0')}` : r.payment_date, title: `Return for ${long(ym(r.return_month))}`,
      cents: r.return_cents, note: r.status === 'paid' ? 'Paid' : r.status === 'reinvested' ? 'Reinvested' : r.status === 'held' ? 'On hold' : r.disposition === 'reinvest' ? 'Reinvested' : 'To be paid',
      state: done ? 'done' : 'now', estimated: false });
  }
  let key = lastMonth ? addMonth(lastMonth, 1) : nextDate ? addMonth(ym(nextDate), -1) : null;
  const todayKey = ym(today);
  for (let n = 0; key && n < ahead; key = addMonth(key, 1)) {
    if (key > addMonth(todayKey, 12)) break;
    const cents = estimateFor(key);
    if (cents <= 0) continue;
    const dim = daysInMonth(Number(key.slice(0, 4)), Number(key.slice(5, 7)));
    schedule.push({ key: `e${key}`, date: reinvest ? `${key}-${String(dim).padStart(2, '0')}` : payDay(key), title: `Return for ${long(key)}`, cents, note: reinvest ? 'To be reinvested' : 'To be paid', state: 'future', estimated: true });
    n++;
  }
  // the account by month: from the first Investment Date to this month, then the projection
  const first = active.map((x) => ym(x.investment_date)).sort()[0];
  const labels: string[] = []; const invested: Array<number | null> = []; const returns: Array<number | null> = []; const projected: Array<number | null> = [];
  if (first) {
    let cum = 0; let k = first; let guard = 0;
    const rowsBy = new Map<string, ReturnRow[]>();
    for (const r of asc) rowsBy.set(ym(r.return_month), [...(rowsBy.get(ym(r.return_month)) ?? []), r]);
    const end = todayKey;
    while (k <= end && guard++ < 240) {
      const rs = rowsBy.get(k) ?? [];
      cum += rs.reduce((s, r) => s + r.return_cents, 0);
      const inv = active.filter((x) => ym(x.investment_date) <= k).reduce((s, x) => s + x.principal_cents, 0)
        + asc.filter((r) => ym(r.return_month) <= k && r.disposition === 'reinvest').reduce((s, r) => s + r.return_cents, 0);
      labels.push(short(k)); invested.push(inv); returns.push(cum); projected.push(null);
      k = addMonth(k, 1);
    }
    projected[projected.length - 1] = cum;
    let p = cum;
    for (let n = 0; n < 6; n++, k = addMonth(k, 1)) {
      const rm = addMonth(k, -1);
      p += lastMonth && rm <= lastMonth ? 0 : estimateFor(rm);
      labels.push(short(k)); invested.push(null); returns.push(null); projected.push(p);
    }
  }
  return { investedCents, paidCents, reinvestedCents, earnedCents, next, schedule, chart: { labels, invested, returns, projected } };
}
