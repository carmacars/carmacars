// The investor-safe sheets of the CarmaCars model workbook (CarmaCars_Investor_Model.xlsx, "Investment calculator" and
// "Fund a car (owner program)"), as plain functions. Each line is the workbook's own formula, so the page, the
// downloaded .xlsx (features/investor-model/workbook.ts writes the same formulas) and the workbook agree:
//   - month n of 36 is paid on EDATE(start, n); months 1 to the lockup (6) earn nothing;
//   - each later month earns balance x rate / 12; reinvested, it is added to the balance and earns from the next month.
// Money here is in dollars, unrounded, as a spreadsheet keeps it; the page rounds to the cent when it shows a figure.
// Nothing here reads the fleet, its use or its costs: these are the investor's and an owner's own inputs.
import { addMonths } from '../deck/returns.ts';

export interface CalcInputs { amount: number; start: string; rate: number; lockupMonths: number; reinvest: boolean; months?: number }
export interface CalcRow { n: number; date: string; phase: 'Lockup' | 'Earning'; balanceStart: number; earned: number; reinvested: number; paid: number;
  cumEarned: number; cumPaid: number; balanceEnd: number }
export interface CalcResult {
  rows: CalcRow[];
  monthlyReturn: number; monthlyPayout: number; yearlyReturn: number; lockupEnds: string; firstPayment: string;
  paidBy24: number; paidBy36: number; earnedBy36: number; balance36: number; value36: number; multiple36: number; belowMinimum: boolean;
}

export const INVESTMENT_MIN = 20_000;
export const CALC_DEFAULTS = { amount: 50_000, rate: 0.3, lockupMonths: 6, reinvest: false } as const;

/** The "Investment calculator" sheet: the results block (rows 13 to 23) and the 36-month schedule (rows 28 to 63). */
export function investmentCalc(i: CalcInputs, min = INVESTMENT_MIN): CalcResult {
  const months = i.months ?? 36;
  const rows: CalcRow[] = [];
  let bal = i.amount, cumE = 0, cumP = 0;
  for (let n = 1; n <= months; n++) {
    const earned = n <= i.lockupMonths ? 0 : (bal * i.rate) / 12;          // E = IF(A<=lockup, 0, D * rate / 12)
    const reinvested = i.reinvest ? earned : 0;                            // F = IF(reinvest = "Yes", E, 0)
    const paid = earned - reinvested;                                      // G = E - F
    cumE += earned; cumP += paid;
    const end = bal + reinvested;                                          // J = D + F
    rows.push({ n, date: addMonths(i.start, n), phase: n <= i.lockupMonths ? 'Lockup' : 'Earning', balanceStart: bal, earned, reinvested, paid, cumEarned: cumE, cumPaid: cumP, balanceEnd: end });
    bal = end;
  }
  const sumPaid = (to: number) => rows.filter((r) => r.n <= to).reduce((s, r) => s + r.paid, 0);
  const last = rows[rows.length - 1];
  const balance36 = last?.balanceEnd ?? i.amount;
  const value36 = balance36 + (last?.cumPaid ?? 0);
  return {
    rows,
    monthlyReturn: (i.amount * i.rate) / 12,
    monthlyPayout: i.reinvest ? 0 : (i.amount * i.rate) / 12,
    yearlyReturn: i.amount * i.rate,
    lockupEnds: addMonths(i.start, i.lockupMonths),
    firstPayment: addMonths(i.start, i.lockupMonths + 1),
    paidBy24: sumPaid(24),
    paidBy36: sumPaid(36),
    earnedBy36: rows.reduce((s, r) => s + r.earned, 0),
    balance36,
    value36,
    multiple36: i.amount ? value36 / i.amount : 0,
    belowMinimum: i.amount < min
  };
}

/** The "How it works" examples table: paid out, not reinvested. */
export function howItWorksRow(amount: number, rate: number, lockupMonths = 6) {
  const monthly = (amount * rate) / 12;
  return { amount, monthly, yearly: monthly * 12, by24: monthly * Math.max(0, 24 - lockupMonths), by36: monthly * Math.max(0, 36 - lockupMonths) };
}
export const HOW_IT_WORKS_AMOUNTS = [20_000, 50_000, 100_000, 250_000];

// ---------------------------------------------------------------- Fund a car (owner program)
export interface CarInputs { name: string; price: number; dailyRate: number; daysPerMonth: number; ownerShare: number; commissions: number; insuranceFee: number; trackerFee: number; depreciation: number }
export interface CarResult {
  gross: number; commissions: number; company: number; ownerShare: number; insurance: number; tracker: number; cash: number; depreciation: number; net: number;
  yearlyCash: number; yearlyDepreciation: number; yearlyNet: number; roi: number; cashYield: number; paybackMonths: number | null; upfront: number;
}
// r35: the deck's figures (features/deck/pitch.ts): $112 earned per rented day (October actual) and 25 rented days, an
// illustration; the monthly fees are the investor's to enter from their agreement (investor pages never state them)
export const CAR_DEFAULTS: CarInputs = { name: 'Example car', price: 7000, dailyRate: 112, daysPerMonth: 25, ownerShare: 0.7, commissions: 0, insuranceFee: 0, trackerFee: 0, depreciation: 0.15 };
export const BLANK_CAR: CarInputs = { name: '', price: 0, dailyRate: 0, daysPerMonth: 0, ownerShare: 0.7, commissions: 0, insuranceFee: 0, trackerFee: 0, depreciation: 0.15 };

/** One car's column of the "Fund a car" sheet (rows "Monthly", "Yearly", "Return on the car"). */
export function fundCar(c: CarInputs): CarResult {
  const gross = c.dailyRate * c.daysPerMonth;
  const commissions = gross * c.commissions;
  const company = (gross - commissions) * (1 - c.ownerShare);
  const ownerShare = gross - commissions - company;
  const cash = ownerShare - c.insuranceFee - c.trackerFee;
  const depreciation = (c.price * c.depreciation) / 12;
  const net = cash - depreciation;
  const yearlyCash = cash * 12, yearlyDepreciation = depreciation * 12, yearlyNet = yearlyCash - yearlyDepreciation;
  return { gross, commissions, company, ownerShare, insurance: c.insuranceFee, tracker: c.trackerFee, cash, depreciation, net, yearlyCash, yearlyDepreciation, yearlyNet,
    roi: c.price ? yearlyNet / c.price : 0, cashYield: c.price ? yearlyCash / c.price : 0, paybackMonths: cash > 0 ? c.price / cash : null, upfront: 2 * (c.insuranceFee + c.trackerFee) };
}

/** The "All cars" column: sums, and the ratios over the summed prices. */
export function fundCars(cars: CarInputs[]) {
  const each = cars.map(fundCar);
  const sum = (k: keyof CarResult) => each.reduce((s, r) => s + (Number(r[k]) || 0), 0);
  const price = cars.reduce((s, c) => s + c.price, 0);
  const cash = sum('cash');
  const total = { gross: sum('gross'), commissions: sum('commissions'), company: sum('company'), ownerShare: sum('ownerShare'), insurance: sum('insurance'), tracker: sum('tracker'), cash,
    depreciation: sum('depreciation'), net: sum('net'), yearlyCash: sum('yearlyCash'), yearlyDepreciation: sum('yearlyDepreciation'), yearlyNet: sum('yearlyNet'),
    roi: price ? sum('yearlyNet') / price : 0, cashYield: price ? sum('yearlyCash') / price : 0, paybackMonths: cash > 0 ? price / cash : null, upfront: sum('upfront') };
  return { each, total };
}

/** Owners are paid on the 10th of the month after each revenue month: the 12-month payout schedule beside the sheet. */
export function carPayoutSchedule(firstMonth: string, monthlyCash: number) {
  return Array.from({ length: 12 }, (_, k) => {
    const m = addMonths(firstMonth.slice(0, 7) + '-01', k);
    const paid = addMonths(m, 1).slice(0, 8) + '10';
    return { month: m, paidOn: paid, payout: monthlyCash, cumulative: monthlyCash * (k + 1) };
  });
}
