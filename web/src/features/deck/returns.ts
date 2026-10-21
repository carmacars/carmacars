// The Investment Agreement's Return, computed in the browser for the deck's examples and calculator. The same rules as
// the database (public.calc_investment_return and app.accrue_investment_return, migrations 0003 and 0010) and the
// agreement (sections 3 and 4, Schedule B):
//   - no Return is earned for the Lockup Period (the Investment Date to the day before the Lockup End Date, six months
//     later by default);
//   - each Return Month (each calendar month or part of one from the Lockup End Date) earns one twelfth of the Yearly
//     Percentage on the Invested Amount at the start of the month, pro-rated by days for a part month, rounded to the cent;
//   - a paid Return is paid on the Payment Date (the 15th of the next month by default);
//   - a reinvested Return is added to the Invested Amount on the last day of its Return Month, so the next month earns
//     on the larger amount.
// Dates are calendar dates (YYYY-MM-DD), handled in UTC so no time zone moves a day. Money is integer cents.

export interface ReturnInputs {
  /** The Invested Amount on the Investment Date, in cents. */
  amountCents: number;
  /** The Yearly Percentage in basis points (3000 = 30%). */
  yearlyBps: number;
  /** The Investment Date, YYYY-MM-DD. */
  investmentDate: string;
  /** How long to show, in whole years from the Investment Date. */
  years: number;
  /** How many Return Months are reinvested before Returns are paid: 0 = paid from the start, Infinity = always reinvested. */
  reinvestMonths: number;
  lockupMonths?: number;
  paymentDay?: number;
}

export interface ReturnMonth {
  n: number;
  month: string;          // first day of the Return Month
  openingCents: number;   // the Invested Amount at the start of the month
  daysEarning: number;
  daysInMonth: number;
  returnCents: number;
  mode: 'reinvest' | 'pay';
  paymentDate: string | null;
  closingCents: number;   // the Invested Amount at the end of the month
}

export interface ReturnResult {
  lockupEndDate: string;
  endDate: string;           // the last day shown (the day before the anniversary)
  months: ReturnMonth[];
  firstPaymentDate: string | null;
  monthsToFirstPayment: number | null;
  /** The Return of the first full paid month (what a month pays once the Returns are paid). */
  monthlyPaymentCents: number | null;
  totalPaidCents: number;
  totalReinvestedCents: number;
  totalReturnCents: number;
  finalInvestedCents: number;
}

const parse = (s: string) => { const [y, m, d] = s.split('-').map(Number); return { y, m, d }; };
const iso = (y: number, m: number, d: number) => `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
export const daysInMonth = (y: number, m: number) => new Date(Date.UTC(y, m, 0)).getUTCDate();
const dayNum = (s: string) => { const { y, m, d } = parse(s); return Date.UTC(y, m - 1, d) / 86_400_000; };
const fromNum = (n: number) => { const t = new Date(n * 86_400_000); return iso(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()); };

/** A date plus whole months, as PostgreSQL adds an interval: the day is kept, or the month's last day if shorter. */
export function addMonths(date: string, months: number): string {
  const { y, m, d } = parse(date);
  const idx = y * 12 + (m - 1) + months;
  const ny = Math.floor(idx / 12), nm = (idx % 12) + 1;
  return iso(ny, nm, Math.min(d, daysInMonth(ny, nm)));
}
export const addDays = (date: string, days: number) => fromNum(dayNum(date) + days);

/** One Return Month, exactly as public.calc_investment_return: round(invested x bps x days / (120000 x days in month)). */
export function monthlyReturnCents(investedCents: number, yearlyBps: number, daysEarning: number, dim: number): number {
  const num = BigInt(Math.round(investedCents)) * BigInt(yearlyBps) * BigInt(daysEarning);
  const den = 120000n * BigInt(dim);
  // half away from zero, as PostgreSQL's round(numeric); amounts here are never negative
  return Number((2n * num + den) / (2n * den));
}

export function computeReturns(i: ReturnInputs): ReturnResult {
  const lockupMonths = i.lockupMonths ?? 6;
  const payDay = i.paymentDay ?? 15;
  const lockupEnd = addMonths(i.investmentDate, lockupMonths);
  const end = addDays(addMonths(i.investmentDate, Math.round(i.years * 12)), -1);
  const months: ReturnMonth[] = [];
  let invested = Math.round(i.amountCents);
  let { y, m } = parse(lockupEnd);
  let n = 0;
  while (dayNum(iso(y, m, 1)) <= dayNum(end)) {
    const dim = daysInMonth(y, m);
    const first = Math.max(dayNum(iso(y, m, 1)), dayNum(lockupEnd));
    const last = Math.min(dayNum(iso(y, m, dim)), dayNum(end));
    const days = Math.max(0, last - first + 1);
    const ret = monthlyReturnCents(invested, i.yearlyBps, days, dim);
    const mode: 'reinvest' | 'pay' = n < i.reinvestMonths ? 'reinvest' : 'pay';
    const ny = m === 12 ? y + 1 : y, nm = m === 12 ? 1 : m + 1;
    const pay = mode === 'pay' ? iso(ny, nm, Math.min(payDay, daysInMonth(ny, nm))) : null;
    const closing = invested + (mode === 'reinvest' ? ret : 0);
    n += 1;
    months.push({ n, month: iso(y, m, 1), openingCents: invested, daysEarning: days, daysInMonth: dim, returnCents: ret, mode, paymentDate: pay, closingCents: closing });
    invested = closing;
    y = ny; m = nm;
  }
  const paid = months.filter((x) => x.mode === 'pay');
  const firstPay = paid.find((x) => x.returnCents > 0)?.paymentDate ?? null;
  const full = paid.find((x) => x.daysEarning === x.daysInMonth);
  const sum = (xs: ReturnMonth[]) => xs.reduce((a, x) => a + x.returnCents, 0);
  return {
    lockupEndDate: lockupEnd,
    endDate: end,
    months,
    firstPaymentDate: firstPay,
    monthsToFirstPayment: firstPay ? monthsBetween(i.investmentDate, firstPay) : null,
    monthlyPaymentCents: full ? full.returnCents : null,
    totalPaidCents: sum(paid),
    totalReinvestedCents: sum(months.filter((x) => x.mode === 'reinvest')),
    totalReturnCents: sum(months),
    finalInvestedCents: invested
  };
}

/** Whole and part months between two dates, to one decimal (for "first payment about 7.5 months after you invest"). */
export function monthsBetween(a: string, b: string): number {
  const pa = parse(a), pb = parse(b);
  let whole = (pb.y - pa.y) * 12 + (pb.m - pa.m);
  if (pb.d < pa.d) whole -= 1;
  const anchor = addMonths(a, whole);
  const next = addMonths(a, whole + 1);
  const frac = (dayNum(b) - dayNum(anchor)) / (dayNum(next) - dayNum(anchor));
  return Math.round((whole + frac) * 10) / 10;
}

/** The first day of the month after a date: the calculator's default Investment Date. */
export function firstOfNextMonth(today: string): string {
  const { y, m } = parse(today);
  return m === 12 ? iso(y + 1, 1, 1) : iso(y, m + 1, 1);
}

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
export const longDate = (s: string) => { const { y, m, d } = parse(s); return `${MONTHS[m - 1]} ${d}, ${y}`; };
export const monthLabel = (s: string) => { const { y, m } = parse(s); return `${MONTHS[m - 1]} ${y}`; };
export const shortMonth = (s: string) => { const { y, m } = parse(s); return `${MONTHS[m - 1].slice(0, 3)} ${String(y).slice(2)}`; };
