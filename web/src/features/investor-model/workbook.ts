// The investor-safe workbook, generated fresh for each download: "Read me", "How it works (summary)", "Investment
// calculator" and "Fund a car (owner program)" with the same layout and formulas as the CarmaCars model workbook
// (CarmaCars_Investors_Share.xlsx), filled with the investor's own numbers, and "My investment": their records and the
// projected schedule as values. Never anything about the fleet, its use, its insurance or the company's costs: the
// internal sheets are built only by features/finance-model/workbook.ts, for Admins.
import { FMT, S, Workbook, banner, section, colLetter, BLACK, GREEN, GREY, MUTED, PINK, RED, WHITE } from '../../lib/xlsx.ts';
import { CAR_DEFAULTS, carDefaults, type CarInputs } from './calc.ts';
import { EXAMPLE_AMOUNTS, FOOTNOTES, RAISE, TERMS } from '../deck/pitch.ts';
import type { MineSummary } from './mine.ts';

export interface InvestorBook {
  multiplier: number | null;          // the company's headline figure (deck_settings.deck_multiplier), lawyer-approved wording
  rate: number;                       // the investor's Yearly Percentage (or the current offer), as a fraction
  minimum: number;                    // dollars
  lockupMonths: number;
  amount: number;                     // dollars, for the calculator
  start: string;                      // YYYY-MM-DD, for the calculator
  reinvest: boolean;
  investorName?: string | null;
  company?: string | null;            // the legal name the agreements carry
  car?: CarInputs;
  carFirstMonth?: string;
  dailyRateCents?: number | null;     // the Program setting for the Fund a car default daily rate
  mine?: MineSummary | null;          // the investor's own records (absent for a preview)
  generatedOn: string;                // YYYY-MM-DD
}

export const SHEETS = { readMe: 'Read me', how: 'How it works (summary)', calc: 'Investment calculator', car: 'Fund a car (owner program)', mine: 'My investment' } as const;

export function readMe(wb: Workbook, tabs: Array<[string, string, string]>, lines: string[], company: string) {
  const rm = wb.sheet(SHEETS.readMe, { tab: BLACK, widths: { A: 34, B: 22, C: 70 }, freeze: 'A3', grid: false, landscape: false });
  banner(rm, 1, 'CarmaCars  |  Investor and owner model', 3, 'What goes around, drives around.  |  All amounts in Canadian dollars (CAD)');
  ['Tab', 'Audience', 'What it does'].forEach((h, i) => rm.put(`${'ABC'[i]}4`, h, S.head('left')));
  let r = 5;
  for (const [t, a, d] of tabs) {
    const internal = a.startsWith('INTERNAL');
    rm.put(`A${r}`, t, { bold: true, border: 'box', wrap: true }).put(`B${r}`, a, { bold: true, color: internal ? RED : GREEN, border: 'box', wrap: true }).put(`C${r}`, d, { border: 'box', wrap: true }).height(r, 32);
    r++;
  }
  r++;
  section(rm, r++, 'Before you share', 3, RED);
  for (const l of lines) { rm.merge(`A${r}:C${r}`).put(`A${r}`, l, { wrap: true }); r++; }
  r++;
  section(rm, r++, 'Colour legend', 3);
  rm.put(`A${r}`, 'Blue text on cream', S.input()).put(`B${r}`, 'Input', { bold: true }).put(`C${r}`, 'Type over these cells. Everything else is a formula.'); r++;
  rm.put(`A${r}`, 'Black text', { border: 'box' }).put(`B${r}`, 'Formula', { bold: true }).put(`C${r}`, 'Calculated from the inputs. Do not overwrite.'); r++;
  r++;
  section(rm, r++, 'Legal entity', 3);
  rm.merge(`A${r}:C${r}`).put(`A${r}`, `Investment and owner agreements are with ${company}. The signed agreement always governs over this model.`, { wrap: true }).height(r, 28);
  return rm;
}

export function howItWorks(wb: Workbook, b: Pick<InvestorBook, 'multiplier' | 'rate' | 'minimum' | 'lockupMonths' | 'company'>) {
  const hw = wb.sheet(SHEETS.how, { tab: RED, widths: { A: 30, B: 20, C: 20, D: 24, E: 24 }, freeze: 'A3', grid: false, landscape: false });
  banner(hw, 1, 'Invest in CarmaCars', 5, 'How your investment works  |  All amounts in CAD');
  hw.merge('A4:E4').merge('A5:E5').merge('A6:E6');
  if (b.multiplier && b.multiplier > 0) {
    hw.put('A4', `${b.multiplier}x`, { bold: true, color: RED, size: 40, align: 'center' }).height(4, 56);
    hw.put('A5', 'multiplier on money invested in the fleet', { bold: true, size: 14, align: 'center' }).height(5, 22);
    hw.put('A6', `CarmaCars' figure. ${FOOTNOTES.internal}`, { italic: true, size: 9, color: MUTED, align: 'center' });
  }
  // r35: the terms of the 2026 deck (features/deck/pitch.ts), the same as every investor page
  let r = 8;
  section(hw, r++, 'The terms in plain words', 5, RED);
  for (const [k, v] of TERMS) {
    hw.put(`A${r}`, k, { bold: true, border: 'box', bg: GREY, wrap: true }).merge(`B${r}:E${r}`).put(`B${r}`, v, { border: 'box', wrap: true }).height(r, 30);
    for (const c of 'CDE') hw.style(`${c}${r}`, { border: 'box' });
    r++;
  }
  r++;
  section(hw, r++, `Option 1 examples: simple interest, paid monthly`, 5);
  hw.put(`A${r}`, 'Low end of the yearly rate').put(`B${r}`, RAISE.option1.lowPct / 100, S.input(FMT.PCT)); const lo = `$B$${r}`; r++;
  hw.put(`A${r}`, 'High end of the yearly rate').put(`B${r}`, RAISE.option1.highPct / 100, S.input(FMT.PCT)); const hi = `$B$${r}`; r += 2;
  ['Amount invested', 'Monthly, low end', 'Monthly, high end', 'Yearly, low end', 'Yearly, high end'].forEach((h, i) => hw.put(`${'ABCDE'[i]}${r}`, h, S.head()));
  hw.height(r, 30); r++;
  for (const amt of EXAMPLE_AMOUNTS) {
    hw.put(`A${r}`, amt, S.input(FMT.CUR)).put(`B${r}`, `=A${r}*${lo}/12`, S.cell(FMT.CUR)).put(`C${r}`, `=A${r}*${hi}/12`, S.cell(FMT.CUR))
      .put(`D${r}`, `=B${r}*12`, S.cell(FMT.CUR)).put(`E${r}`, `=C${r}*12`, S.cell(FMT.CUR));
    r++;
  }
  r++;
  hw.merge(`A${r}:E${r}`).put(`A${r}`, `Option 2 is a ${RAISE.option2.lowPct} to ${RAISE.option2.highPct}% profit share from the cars this money puts on the road. Use the Investment calculator tab for your own amount and start date.`, { italic: true, size: 9, wrap: true }).height(r, 26); r++;
  hw.merge(`A${r}:E${r}`).put(`A${r}`, `This summary is for information only and is not an offer by itself. ${FOOTNOTES.offer}. Like any investment, it carries risk.`, S.note()).height(r, 26);
  return hw;
}

/** The "Investment calculator" sheet, cell for cell as the workbook: inputs B5:B10, results B13:B23, schedule rows 28 to 63. */
export function calculator(wb: Workbook, b: Pick<InvestorBook, 'amount' | 'start' | 'rate' | 'lockupMonths' | 'reinvest' | 'minimum' | 'investorName' | 'company'>) {
  const ic = wb.sheet(SHEETS.calc, { tab: RED, widths: { A: 34, B: 18, C: 14, D: 18, E: 16, F: 16, G: 16, H: 18, I: 18, J: 18 }, freeze: 'A3', grid: false });
  banner(ic, 1, 'CarmaCars  |  Investment calculator', 10, 'Enter the blue cells. Everything else updates.  |  All amounts in CAD');
  const minTxt = `CA$${b.minimum.toLocaleString('en-CA')}`;
  section(ic, 4, 'Your inputs', 4, RED);
  ic.put('A5', 'Investor name (optional)').merge('B5:D5').put('B5', b.investorName || 'Example investor', { ...S.input(), align: 'left' });
  ic.put('A6', `Amount invested (minimum ${minTxt})`).put('B6', b.amount, S.input(FMT.CUR));
  ic.put('A7', 'Start date (funds received)').put('B7', { date: b.start }, S.input(FMT.DATE));
  ic.put('A8', 'Annual return (set per investor)').put('B8', b.rate, S.input(FMT.PCT));
  ic.put('A9', 'Lockup (months, no return accrues)').put('B9', b.lockupMonths, S.input(FMT.INT));
  ic.put('A10', 'Reinvest returns? (Yes / No)').put('B10', b.reinvest ? 'Yes' : 'No', S.input());
  ic.put('C6', `=IF(B6<${b.minimum},"Below the ${minTxt} minimum","OK")`, { bold: true, color: RED });
  ic.validate({ sqref: 'B6', min: b.minimum, error: `The minimum investment is ${minTxt}.` });
  ic.validate({ sqref: 'B10', list: ['Yes', 'No'] });
  ic.validate({ sqref: 'B8', min: 0, max: 1, error: 'Enter a percentage, for example 30%.' });
  section(ic, 12, 'Your results', 4, RED);
  const res: Array<[string, string, string]> = [
    ['Monthly return once the lockup ends', '=B6*B8/12', FMT.CUR2],
    ['Monthly payout to you', '=IF(B10="Yes",0,B6*B8/12)', FMT.CUR2],
    ['Yearly return at your rate', '=B6*B8', FMT.CUR],
    ['Lockup ends', '=EDATE(B7,B9)', FMT.DATE],
    ['First monthly payment', '=EDATE(B7,B9+1)', FMT.DATE],
    ['Total paid to you by month 24', '=SUMIF(A28:A63,"<=24",G28:G63)', FMT.CUR],
    ['Total paid to you by month 36', '=SUMIF(A28:A63,"<=36",G28:G63)', FMT.CUR],
    ['Total returns earned by month 36 (paid + reinvested)', '=SUM(E28:E63)', FMT.CUR],
    ['Balance invested at month 36', '=J63', FMT.CUR],
    ['Total value at month 36 (balance + paid out)', '=J63+I63', FMT.CUR],
    ['Your value multiple at month 36 (value / amount invested)', '=IFERROR((J63+I63)/B6,0)', FMT.MULT]
  ];
  res.forEach(([l, f, fmt], i) => {
    const big = l.startsWith('Monthly payout');
    ic.put(`A${13 + i}`, l, { border: 'box', bg: GREY }).put(`B${13 + i}`, f, { fmt, bold: big, color: big ? RED : BLACK, border: 'box', align: 'right' });
  });
  ic.merge('F4:J4').put('F4', 'Terms in brief', { bold: true, color: WHITE, bg: BLACK, size: 11 });
  for (const c of 'GHIJ') ic.style(`${c}4`, { bg: BLACK });
  // r35: the terms of the 2026 deck (features/deck/pitch.ts)
  [`Option 1: ${RAISE.option1.lowPct} to ${RAISE.option1.highPct}% a year, paid monthly,`, 'simple interest.', `Option 2: ${RAISE.option2.lowPct} to ${RAISE.option2.highPct}% profit share from the`,
    'cars this money puts on the road.', 'Lockup above: the months with no return, when', 'your agreement has one.', 'Choose Yes above to see the returns reinvested.',
    ...(b.company ? [`Invested with ${b.company}.`] : []), 'Final terms are set in the signed agreement.']
    .forEach((n, i) => ic.merge(`F${5 + i}:J${5 + i}`).put(`F${5 + i}`, n, { size: 9 }));
  section(ic, 25, 'Payout schedule, 36 months from the start date (months 24 and 36 highlighted)', 10, RED);
  ['Month', 'Payment date', 'Phase', 'Balance at start', 'Return earned', 'Reinvested', 'Paid to you', 'Cumulative returns', 'Cumulative paid', 'Balance at end']
    .forEach((h, i) => ic.put(`${colLetter(i + 1)}27`, h, S.dark()));
  ic.height(27, 30);
  for (let n = 1; n <= 36; n++) {
    const rr = 27 + n;
    const hl = n === 24 || n === 36 ? { bg: PINK, bold: true } : {};
    ic.put(`A${rr}`, n, S.cell(FMT.INT, { align: 'center', ...hl }))
      .put(`B${rr}`, `=EDATE($B$7,A${rr})`, S.cell(FMT.DATE, { align: 'center', ...hl }))
      .put(`C${rr}`, `=IF(A${rr}<=$B$9,"Lockup","Earning")`, S.cell(undefined, { align: 'center', ...hl }))
      .put(`D${rr}`, n === 1 ? '=$B$6' : `=J${rr - 1}`, S.cell(FMT.CUR, hl))
      .put(`E${rr}`, `=IF(A${rr}<=$B$9,0,D${rr}*$B$8/12)`, S.cell(FMT.CUR2, hl))
      .put(`F${rr}`, `=IF($B$10="Yes",E${rr},0)`, S.cell(FMT.CUR2, hl))
      .put(`G${rr}`, `=E${rr}-F${rr}`, S.cell(FMT.CUR2, hl))
      .put(`H${rr}`, n === 1 ? `=E${rr}` : `=H${rr - 1}+E${rr}`, S.cell(FMT.CUR, hl))
      .put(`I${rr}`, n === 1 ? `=G${rr}` : `=I${rr - 1}+G${rr}`, S.cell(FMT.CUR, hl))
      .put(`J${rr}`, `=D${rr}+F${rr}`, S.cell(FMT.CUR, hl));
  }
  ic.merge('A65:J65').put('A65', 'Illustration only. Payment dates are shown one calendar month apart from the start date; the agreement sets the actual payment day.', S.note()).height(65, 24);
  return ic;
}

/** "Fund a car (owner program)": three cars side by side and the total, with the 12-month payout schedule. */
export function fundACar(wb: Workbook, car: CarInputs = CAR_DEFAULTS, firstMonth = '2026-12-01', company?: string | null) {
  const fc = wb.sheet(SHEETS.car, { tab: RED, widths: { A: 44, B: 18, C: 18, D: 18, E: 18, F: 3, G: 16, H: 16, I: 16, J: 16 }, freeze: 'B4', grid: false });
  banner(fc, 1, 'CarmaCars  |  Fund a car (owner program)', 10, 'For owners who place a car in the program under an owner agreement  |  All amounts in CAD');
  fc.put('A3', 'Up to 3 cars side by side', S.head('left'));
  ['Car 1', 'Car 2', 'Car 3', 'All cars'].forEach((h, i) => fc.put(`${'BCDE'[i]}3`, h, S.head()));
  section(fc, 4, 'Your inputs (per car)', 5);
  const rows: Array<[string, [string | number, string | number, string | number], string | undefined]> = [
    ['Car (make, model, year)', [car.name || 'Example car', '', ''], undefined],
    ['Purchase price', [car.price, 0, 0], FMT.CUR],
    ['Daily rate charged to renters', [car.dailyRate, 0, 0], FMT.CUR],
    ['Expected rented days per month (your estimate)', [car.daysPerMonth, 0, 0], FMT.INT],
    ['Your share of rental revenue', [car.ownerShare, 0.7, 0.7], FMT.PCT],
    ['Booking commissions deducted before the split', [car.commissions, 0, 0], FMT.PCT],
    ['Monthly insurance fee (per your agreement)', [car.insuranceFee, 0, 0], FMT.CUR],
    ['Monthly tracker fee (per your agreement)', [car.trackerFee, 0, 0], FMT.CUR],
    ['Depreciation per year (% of price)', [car.depreciation, 0.15, 0.15], FMT.PCT]
  ];
  const ROW: number[] = [];
  let r = 5;
  rows.forEach(([l, vals, fmt], i) => {
    fc.put(`A${r}`, l, { border: 'box', bg: GREY });
    'BCD'.split('').forEach((c, j) => fc.put(`${c}${r}`, vals[j] as string | number, S.input(fmt)));
    ROW[i] = r; r++;
  });
  fc.put(`A${r}`, 'First month in the program').put(`B${r}`, { date: firstMonth }, S.input(FMT.MON));
  const fm = `$B$${r}`; r += 2;
  fc.validate({ sqref: `B${ROW[4]}:D${ROW[5]}`, min: 0, max: 1, error: 'Enter a percentage between 0% and 100%.' });
  fc.validate({ sqref: `B${ROW[8]}:D${ROW[8]}`, min: 0, max: 1, error: 'Enter a percentage between 0% and 100%.' });
  fc.validate({ sqref: `B${ROW[3]}:D${ROW[3]}`, kind: 'whole', min: 0, max: 31, error: 'Enter between 0 and 31 days.' });
  const [, price, rate, days, share, comm, insf, trkf, dep] = ROW as [number, number, number, number, number, number, number, number, number];
  const OUT: Record<string, number> = {};
  const line = (key: string, label: string, tmpl: (c: string) => string, fmt: string = FMT.CUR, total: string | true = true, o: { bold?: boolean; top?: boolean; color?: string } = {}) => {
    fc.put(`A${r}`, label, { bold: o.bold });
    for (const c of 'BCD') fc.put(`${c}${r}`, tmpl(c), { fmt, bold: o.bold, color: o.color, border: o.top ? 'top' : undefined });
    fc.put(`E${r}`, total === true ? `=SUM(B${r}:D${r})` : total, { fmt, bold: true, color: o.color, bg: GREY, border: o.top ? 'top' : undefined });
    OUT[key] = r; r++;
  };
  section(fc, r++, 'Monthly', 5);
  line('gross', 'Rental revenue', (c) => `=${c}${rate}*${c}${days}`);
  line('comm', 'Less: booking commissions', (c) => `=${c}${OUT.gross}*${c}${comm}`);
  line('co', 'Less: CarmaCars share', (c) => `=(${c}${OUT.gross}-${c}${OUT.comm})*(1-${c}${share})`);
  line('own', 'Your share of rental revenue', (c) => `=${c}${OUT.gross}-${c}${OUT.comm}-${c}${OUT.co}`, FMT.CUR, true, { bold: true, top: true });
  line('ins', 'Less: insurance fee', (c) => `=${c}${insf}`);
  line('trk', 'Less: tracker fee', (c) => `=${c}${trkf}`);
  line('cash', 'Your monthly payout (cash)', (c) => `=${c}${OUT.own}-${c}${OUT.ins}-${c}${OUT.trk}`, FMT.CUR, true, { bold: true, top: true, color: RED });
  line('dep', 'Less: depreciation (not cash)', (c) => `=${c}${price}*${c}${dep}/12`);
  line('net', 'Your monthly net after depreciation', (c) => `=${c}${OUT.cash}-${c}${OUT.dep}`, FMT.CUR, true, { bold: true, top: true });
  r++;
  section(fc, r++, 'Yearly', 5);
  line('ycash', 'Yearly payout (cash)', (c) => `=${c}${OUT.cash}*12`, FMT.CUR, true, { bold: true });
  line('ydep', 'Yearly depreciation', (c) => `=${c}${OUT.dep}*12`);
  line('ynet', 'Yearly net after depreciation', (c) => `=${c}${OUT.ycash}-${c}${OUT.ydep}`, FMT.CUR, true, { bold: true, top: true });
  r++;
  section(fc, r++, 'Return on the car', 5);
  const prices = `SUM(B${price}:D${price})`;
  line('roi', 'ROI per year (net after depreciation / price)', (c) => `=IFERROR(${c}${OUT.ynet}/${c}${price},0)`, FMT.PCT, `=IFERROR(E${OUT.ynet}/${prices},0)`, { bold: true });
  line('yield', 'Cash yield per year (payout / price)', (c) => `=IFERROR(${c}${OUT.ycash}/${c}${price},0)`, FMT.PCT, `=IFERROR(E${OUT.ycash}/${prices},0)`);
  line('pb', 'Payback on cash payouts (months)', (c) => `=IF(${c}${OUT.cash}>0,${c}${price}/${c}${OUT.cash},"n/a")`, FMT.NUM, `=IF(E${OUT.cash}>0,${prices}/E${OUT.cash},"n/a")`, { bold: true });
  line('up', 'Upfront at signing: first and last month fees', (c) => `=2*(${c}${insf}+${c}${trkf})`);
  fc.merge('G3:J3').put('G3', 'Payout schedule, all cars', S.head('left'));
  ['Revenue month', 'Paid on', 'Payout', 'Cumulative'].forEach((h, i) => fc.put(`${'GHIJ'[i]}4`, h, S.dark()));
  for (let n = 1; n <= 12; n++) {
    const rr = 4 + n;
    fc.put(`G${rr}`, `=EDATE(${fm},${n - 1})`, S.cell(FMT.MON, { align: 'center' })).put(`H${rr}`, `=DATE(YEAR(G${rr}),MONTH(G${rr})+1,10)`, S.cell(FMT.DATE, { align: 'center' }))
      .put(`I${rr}`, `=$E$${OUT.cash}`, S.cell(FMT.CUR)).put(`J${rr}`, n === 1 ? `=I${rr}` : `=J${rr - 1}+I${rr}`, S.cell(FMT.CUR));
  }
  fc.merge('G18:J22').put('G18', "Owners are paid monthly on the 10th for the previous month's rentals. You are paid only for days the car is rented; downtime earns nothing. Insurance and tracker fees are shown net here for simplicity.", { size: 9, wrap: true, italic: true });
  r++;
  fc.merge(`A${r}:E${r + 1}`).put(`A${r}`, `Illustration only, based on your own inputs. Your signed owner agreement${company ? ` with ${company}` : ''} sets your actual revenue share and fees. Owners in this program sign owner agreements, not investment agreements.`, S.note());
  return fc;
}

const cents = (c: number) => Math.round(c) / 100;
const STATE: Record<string, string> = { paid: 'Paid', to_be_paid: 'To be paid', held: 'On hold', reinvested: 'Reinvested', projected: 'Projected' };

/** "My investment": the investor's records and the schedule from them, as values (a snapshot of the live page). */
export function myInvestmentSheet(wb: Workbook, m: MineSummary, generatedOn: string, name?: string | null) {
  const ws = wb.sheet(SHEETS.mine, { tab: RED, widths: { A: 34, B: 18, C: 18, D: 18, E: 18, F: 16 }, freeze: 'A3', grid: false });
  banner(ws, 1, 'CarmaCars  |  My investment', 6, `${name ? `${name}  |  ` : ''}From your records on ${generatedOn}  |  All amounts in CAD`);
  section(ws, 4, 'Your investment', 6, RED);
  const facts: Array<[string, number | string | { date: string } | null, string | undefined]> = [
    ['Invested Amount', cents(m.investedCents), FMT.CUR2],
    ['Principal paid in', cents(m.principalCents), FMT.CUR2],
    ['Investment Date', m.startDate ? { date: m.startDate } : null, FMT.DATE],
    ['Yearly Percentage', m.yearlyBps !== null ? m.yearlyBps / 10000 : null, '0.00%'],
    ['Lockup End Date', m.lockupEnd ? { date: m.lockupEnd } : null, FMT.DATE],
    ['Returns paid to you so far', cents(m.payoutsMadeCents), FMT.CUR2],
    ['Payments made', m.payoutsMadeCount, FMT.INT],
    ['Reinvested so far', cents(m.reinvestedCents), FMT.CUR2],
    [m.next?.mode === 'reinvest' ? 'Next Return (date)' : 'Next payment (date)', m.next ? { date: m.next.date } : null, FMT.DATE],
    [m.next?.mode === 'reinvest' ? 'Next Return (amount)' : 'Next payment (amount)', m.next ? cents(m.next.cents) : null, FMT.CUR2]
  ];
  facts.forEach(([l, v, fmt], i) => { ws.put(`A${5 + i}`, l, { border: 'box', bg: GREY }).put(`B${5 + i}`, v as never, S.cell(fmt, { align: 'right' })); });
  let r = 5 + facts.length + 1;
  section(ws, r++, `Schedule, ${m.rows.length} Return Months (${m.reinvest ? 'Returns reinvested' : 'Returns paid monthly'} from here on)`, 6, RED);
  ['Return Month', 'Paid or added on', 'Invested at start', 'Return', 'How', 'Status'].forEach((h, i) => ws.put(`${colLetter(i + 1)}${r}`, h, S.dark()));
  const head = r++;
  for (const x of m.rows) {
    ws.put(`A${r}`, { date: x.month }, S.cell(FMT.MON, { align: 'center' })).put(`B${r}`, { date: x.date }, S.cell(FMT.DATE, { align: 'center' }))
      .put(`C${r}`, cents(x.openingCents), S.cell(FMT.CUR2)).put(`D${r}`, cents(x.returnCents), S.cell(FMT.CUR2, x.recorded ? { bold: true } : {}))
      .put(`E${r}`, x.mode === 'reinvest' ? 'Reinvested' : 'Paid', S.cell(undefined, { align: 'center' })).put(`F${r}`, STATE[x.state] ?? x.state, S.cell(undefined, { align: 'center', color: x.recorded ? BLACK : MUTED }));
    r++;
  }
  if (m.rows.length) {
    ws.put(`A${r}`, 'Total', { bold: true, bg: GREY, border: 'box' }).put(`D${r}`, `=SUM(D${head + 1}:D${r - 1})`, { fmt: FMT.CUR2, bold: true, bg: GREY, border: 'box' });
    ws.put(`E${r}`, 'Paid', { bg: GREY, border: 'box', align: 'center' }).put(`F${r}`, `=SUMIF(E${head + 1}:E${r - 1},"Paid",D${head + 1}:D${r - 1})`, { fmt: FMT.CUR2, bold: true, bg: GREY, border: 'box' });
    r += 2;
  }
  ws.merge(`A${r}:F${r + 1}`).put(`A${r}`, 'Rows marked Paid, To be paid, On hold or Reinvested are your statements. Projected rows use your Invested Amount and Yearly Percentage as your agreement computes a Return; your statement for each month is the record.', S.note());
  return ws;
}

/** The whole investor workbook. */
export function investorWorkbook(b: InvestorBook): Workbook {
  const wb = new Workbook('CarmaCars investor model');
  const company = b.company || 'CarmaCars';
  const tabs: Array<[string, string, string]> = [
    ...(b.mine ? [[SHEETS.mine, 'Investors: your own records', 'Your investment, payouts made, the next payment and the schedule, from your records on the day you downloaded this file.'] as [string, string, string]] : []),
    [SHEETS.how, 'Investors: SAFE TO SHARE', 'Headline figure and the investment terms in plain words.'],
    [SHEETS.calc, 'Investors: SAFE TO SHARE', 'Enter an amount and start date to see the monthly payout and a 36-month payout schedule with dates.'],
    [SHEETS.car, 'Car owners: SAFE TO SHARE', 'Per-car calculator for people who buy a car and place it in the owner program (owner agreements, not investor agreements).']
  ];
  readMe(wb, tabs, ['This copy contains only the tabs that are safe to share with investors and car owners.', 'Formulas recalculate when the file opens; change any blue cell to try your own numbers.'], company);
  if (b.mine) myInvestmentSheet(wb, b.mine, b.generatedOn, b.investorName);
  howItWorks(wb, b);
  calculator(wb, b);
  fundACar(wb, b.car ?? carDefaults(b.dailyRateCents), b.carFirstMonth ?? '2026-12-01', b.company);
  return wb;
}
