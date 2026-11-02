// The full internal workbook (Admin only): the investor-safe tabs, then "Assumptions", "Actuals", "Forecast" and
// "Pro forma 5y", each marked DO NOT SHARE. Actuals are the database's month by month (values); the assumptions are the
// Admin's saved inputs (blue cells); the forecast and the pro forma are live formulas over both, the same steps as
// ./engine.ts, so changing a blue cell in Excel reworks every month. Investors on file are a values row (their own
// agreements' Returns), so the formulas never need anyone's records.
import { FMT, S, Workbook, banner, section, colLetter, BLACK, GREY, MUTED, RED } from '../../lib/xlsx.ts';
import { calculator, fundACar, howItWorks, readMe } from '../investor-model/workbook.ts';
import { DAYS_PER_MONTH, FALLBACK, OPEX_LINES, addYm, investorsOnFile, type ActualMonth, type InvestorOnFile, type Inputs, type Model } from './engine.ts';

export const INTERNAL = { a: 'Assumptions - DO NOT SHARE', act: 'Actuals - DO NOT SHARE', f: 'Forecast - DO NOT SHARE', pf: 'Pro forma 5y - DO NOT SHARE' } as const;
const q = (name: string) => `'${name}'!`;
const N = 60;                         // months on the grid: the launch month and 59 after
const C0 = 3;                         // column C is month 0
const LAST = colLetter(C0 + N - 1);   // BJ
const cols = Array.from({ length: N }, (_, i) => colLetter(C0 + i));
const dollars = (c: number) => Math.round(c) / 100;
const label = (code: string) => code.replace(/_/g, ' ').replace(/^\w/, (x) => x.toUpperCase());

export interface InternalBook {
  actuals: ActualMonth[]; inputs: Inputs; investors: InvestorOnFile[]; model: Model;
  multiplier: number | null; offerRate: number; minimum: number; lockupMonths: number; company: string | null; generatedOn: string; computedAt: string | null;
}

export function internalWorkbook(b: InternalBook): Workbook {
  const wb = new Workbook('CarmaCars model, internal');
  const company = b.company || 'CarmaCars';
  readMe(wb, [
    ['How it works (summary)', 'Investors: SAFE TO SHARE', 'Headline figure and the investment terms in plain words.'],
    ['Investment calculator', 'Investors: SAFE TO SHARE', 'Enter an amount and start date to see the monthly payout and a 36-month payout schedule with dates.'],
    ['Fund a car (owner program)', 'Car owners: SAFE TO SHARE', 'Per-car calculator for people who buy a car and place it in the owner program.'],
    [INTERNAL.a, 'INTERNAL ONLY', 'Growth, utilization ramp, rates, costs, hires, capital raises, the fleet insurance premium and tax. Blue cells are the inputs saved in Admin > Money > Company model.'],
    [INTERNAL.act, 'INTERNAL ONLY', `Real monthly results from the database (accrual revenue before HST, fees, payouts, expenses, investors, cash by method), as of ${b.computedAt ? b.computedAt.slice(0, 16).replace('T', ' ') : b.generatedOn}.`],
    [INTERNAL.f, 'INTERNAL ONLY', 'A = actual month, F = forecast. Runs from the latest complete actual month and the assumptions: EBITDA, investor returns, tax and cash, month by month for 5 years.'],
    [INTERNAL.pf, 'INTERNAL ONLY', 'Years 1 to 5: income statement, cash flow and key ratios, summed from the forecast.']
  ], ['This workbook contains internal tabs (marked DO NOT SHARE). Never send this file as is.',
    'To share with an investor: use the investor portal\'s own download, which contains only the safe tabs and their own numbers.',
    'The investor and owner tabs do not link to any internal tab, so deleting the internal tabs breaks nothing.'], company);
  howItWorks(wb, { multiplier: b.multiplier, rate: b.offerRate, minimum: b.minimum, lockupMonths: b.lockupMonths, company: b.company });
  calculator(wb, { amount: 50_000, start: b.generatedOn, rate: b.offerRate, lockupMonths: b.lockupMonths, reinvest: false, minimum: b.minimum, investorName: null, company: b.company });
  fundACar(wb, undefined, `${b.generatedOn.slice(0, 7)}-01`, b.company);
  const A = assumptions(wb, b);
  const R = actualsSheet(wb, b, A);
  const F = forecast(wb, b, A, R);
  proForma(wb, F);
  return wb;
}

// ---------------------------------------------------------------- Assumptions
type AKey = 'launch' | 'carsIn' | 'add' | 'addMonths' | 'utilIn' | 'utilT' | 'ramp' | 'rateIn' | 'rg' | 'feeIn' | 'keepIn' | 'proc' | 'cg' | 'premium' | 'staff' | 'software' | 'marketing'
  | 'repairs' | 'other' | 'irate' | 'lock' | 'tax' | 'cash0' | 'hireIdx' | 'hireAmt' | 'raiseIdx' | 'raiseAmt' | 'oneIdx' | 'oneAmt';
type ARef = Record<AKey, string> & Record<string, string | undefined>;
function assumptions(wb: Workbook, b: InternalBook): ARef {
  const ws = wb.sheet(INTERNAL.a, { tab: BLACK, widths: { A: 52, B: 18, C: 16, D: 16, E: 60 }, freeze: 'A3', grid: false });
  banner(ws, 1, 'CarmaCars  |  Assumptions  |  INTERNAL, DO NOT SHARE', 5, 'Blue cells are inputs (saved in Admin > Money > Company model). Blank = use the actual base month. CAD unless marked.');
  const i = b.inputs; const ref = {} as ARef;
  const AQ = q(INTERNAL.a);
  let r = 4;
  const put = (key: string, lbl: string, v: number | null | { date: string }, fmt: string | undefined, note = '', input = true) => {
    ws.put(`A${r}`, lbl).put(`B${r}`, v as never, input ? S.input(fmt) : S.cell(fmt, { bg: GREY })).put(`E${r}`, note, { size: 9, color: note.startsWith('ENTER') ? RED : '404040', bold: note.startsWith('ENTER'), wrap: true });
    ref[key] = `${AQ}$B$${r}`; r++;
  };
  section(ws, r++, 'Timing', 5, RED);
  put('launch', 'Launch month (month 0 of the model)', { date: `${i.launchMonth}-01` }, FMT.MON, 'The first month on the grid.');
  section(ws, r++, 'Fleet and utilization', 5, RED);
  put('carsIn', 'Cars at the base month (blank = from the actuals)', i.carsStart, FMT.INT, 'Blank uses the fleet count of the latest complete actual month.');
  put('add', 'Cars added per month', i.carsAddedPerMonth, FMT.NUM, 'Growth of the fleet.');
  put('addMonths', 'Keep adding cars for (months)', i.addMonths, FMT.INT, '');
  put('utilIn', 'Utilization in the base month (blank = from the actuals)', i.utilStart, FMT.PCT, 'Rented days / (cars x days in month).');
  put('utilT', 'Target utilization', i.utilTarget, FMT.PCT, 'ESTIMATE.');
  put('ramp', 'Months to reach the target', i.utilRampMonths, FMT.INT, 'Linear ramp from the base month.');
  section(ws, r++, 'Rates', 5, RED);
  put('rateIn', 'Revenue per rented day (blank = from the actuals)', i.ratePerDay, FMT.CUR2, 'Rental earned / rented days in the base month.');
  put('rg', 'Rate growth per year', i.rateGrowth, FMT.PCT, 'Applied once a year from the base month.');
  put('feeIn', 'Fees as % of rental (blank = from the actuals)', i.feePct, FMT.PCT, 'Company fees (delivery, young driver, coverage, admin, late) over rental.');
  put('keepIn', 'Company keeps, % of rental (blank = from the actuals)', i.companyKeepPct, FMT.PCT, 'After owner and partner shares, commissions and kickbacks.');
  put('proc', 'Payment processing, % of rental and fees', i.processingPct, FMT.PCT, '');
  section(ws, r++, 'Monthly costs (CAD, grow once a year)', 5, RED);
  put('cg', 'Cost growth per year', i.costGrowth, FMT.PCT, '');
  put('premium', 'Fleet insurance premium per year (enter)', i.insurancePremium, FMT.CUR, 'ENTER the fixed annual premium. Blank counts as $0, so profit is overstated until it is entered.');
  put('staff', 'Staff and contractors today', i.staff, FMT.CUR, 'VAs and field staff now on payroll.');
  put('software', 'Software', i.software, FMT.CUR, '');
  put('marketing', 'Marketing', i.marketing, FMT.CUR, '');
  put('repairs', 'Repairs and maintenance (net)', i.repairs, FMT.CUR, '');
  put('other', 'Other (tolls, trackers, parking, towing, other)', i.other, FMT.CUR, '');
  section(ws, r++, 'Investors and tax', 5, RED);
  put('irate', 'Return on planned raises, per year', i.investorRate, FMT.PCT, 'Investors already on file use their own agreements (Forecast row).');
  put('lock', 'Lockup (months)', i.lockupMonths, FMT.INT, '');
  put('tax', 'Corporate tax rate', i.taxRate, FMT.PCT, 'ESTIMATE. Confirm with the accountant.');
  put('cash0', 'Opening cash at the launch month', i.openingCash, FMT.CUR, 'ESTIMATE.');
  // tables: hires, raises, one-time costs (6 rows each; month # from the launch month)
  const table = (title: string, heads: [string, string, string], rows: Array<[string, string | null, number | null]>, key: string) => {
    r++;
    section(ws, r++, title, 5, RED);
    [...heads, 'Month #'].forEach((h, k) => ws.put(`${'ABCD'[k]}${r}`, h, S.dark()));
    r++;
    const first = r;
    for (let k = 0; k < 6; k++) {
      const x = rows[k];
      ws.put(`A${r}`, x?.[0] ?? '', { ...S.input(), align: 'left' }).put(`B${r}`, x?.[1] ? { date: `${x[1]}-01` } : null, S.input(FMT.MON)).put(`C${r}`, x?.[2] ?? null, S.input(FMT.CUR))
        .put(`D${r}`, `=IF(AND(ISNUMBER(B${r}),N(C${r})<>0),(YEAR(B${r})-YEAR(${ref.launch}))*12+MONTH(B${r})-MONTH(${ref.launch}),9999)`, S.cell(FMT.INT, { bg: GREY, align: 'center' }));
      r++;
    }
    ref[`${key}Idx`] = `${AQ}$D$${first}:$D$${r - 1}`; ref[`${key}Amt`] = `${AQ}$C$${first}:$C$${r - 1}`;
  };
  table('Staff hires (step-ups)', ['Role', 'Start month', 'Monthly CAD'], i.hires.map((h) => [h.role, h.start, h.monthly]), 'hire');
  table('Investor capital raises (planned)', ['Note', 'Month funded', 'Amount'], i.raises.map((x, k) => [`Raise ${k + 1}`, x.month, x.amount]), 'raise');
  table('One-time costs', ['What', 'Month paid', 'Amount'], i.oneTime.map((o) => [o.label, o.month, o.amount]), 'one');
  return ref;
}

// ---------------------------------------------------------------- Actuals
type RRef = Record<'flag' | 'flagm' | 'rental' | 'days' | 'cars' | 'fees' | 'owner' | 'partner' | 'comm' | 'kick' | 'proc' | 'invPaid' | 'invIn' | 'latest', number> & Record<string, number | undefined>;
function actualsSheet(wb: Workbook, b: InternalBook, A: ARef): RRef {
  const ws = wb.sheet(INTERNAL.act, { tab: BLACK, widths: { A: 46, B: 40, ...Object.fromEntries(cols.map((c) => [c, 13])) }, freeze: 'C6', grid: false });
  banner(ws, 1, 'CarmaCars  |  Actuals by month  |  INTERNAL, DO NOT SHARE', 12, 'From the database (accrual, before HST, placeholders left out). Filled each hour by the actuals job; the month in progress is not complete.');
  const by = new Map(b.actuals.map((a) => [a.month.slice(0, 7), a]));
  const R = {} as RRef;
  ws.put('A3', 'Month #', S.head('left')).put('B3', 'Source', S.head('left')).put('A4', 'Month', S.head('left')).put('B4', '', { bg: RED }).put('A5', 'Complete month (1 = actual)', S.dark('left')).put('B5', '', { bg: BLACK });
  cols.forEach((c, n) => {
    const key = addYm(b.inputs.launchMonth, n);
    ws.put(`${c}3`, n, { ...S.head(), fmt: FMT.INT }).put(`${c}4`, `=EDATE(${A.launch},${c}$3)`, { ...S.head(), fmt: FMT.MON }).put(`${c}5`, by.get(key)?.complete ? 1 : 0, { ...S.dark(), fmt: FMT.INT });
  });
  R.flag = 5;
  let r = 6;
  ws.put(`A${r}`, 'Month # if complete, else -1', { italic: true, color: MUTED });
  cols.forEach((c) => ws.put(`${c}${r}`, `=IF(${c}$5=1,${c}$3,-1)`, { fmt: FMT.INT, color: MUTED }));
  R.flagm = r++;
  const row = (key: string, lbl: string, src: string, val: (a: ActualMonth) => number | null, fmt: string = FMT.CUR2, bold = false) => {
    ws.put(`A${r}`, lbl, { bold }).put(`B${r}`, src, { size: 9, color: '404040' });
    cols.forEach((c, n) => { const a = by.get(addYm(b.inputs.launchMonth, n)); const v = a ? val(a) : null; ws.put(`${c}${r}`, v, { fmt, bold, bg: a && !a.complete ? GREY : undefined }); });
    R[key] = r++;
  };
  const sec = (t: string) => { r++; section(ws, r++, t, 6); };
  const all = (pick: (a: ActualMonth) => Record<string, unknown> | undefined) => [...new Set(b.actuals.flatMap((a) => Object.keys(pick(a) ?? {})))].sort();
  sec('Rental revenue earned (accrual by day, before HST, placeholders left out)');
  row('rental', 'Total rental revenue', 'Bookings, rental lines, prorated by day', (a) => dollars(a.rental_cents), FMT.CUR2, true);
  row('rentalIns', 'Insurer-billed', 'Bookings billed to an insurer', (a) => dollars(a.rental_insurer_cents));
  row('rentalRen', 'Renter-billed', 'Bookings billed to the renter', (a) => dollars(a.rental_renter_cents));
  for (const seg of all((a) => a.rental_by_segment)) row(`seg_${seg}`, `  ${label(seg)} cars`, 'By who owns the car', (a) => dollars(a.rental_by_segment?.[seg] ?? 0));
  sec('Activity');
  row('days', 'Rented days', 'Booking days inside the month', (a) => a.rented_days, FMT.NUM);
  row('rentals', 'Rentals (active in the month)', 'Bookings with a day in the month', (a) => a.rentals, FMT.INT);
  row('cars', 'Cars on the fleet at month end', 'Vehicles listed or rentable', (a) => a.cars, FMT.INT);
  sec('Fees earned (before HST), by kind');
  for (const k of all((a) => a.fees_by_kind)) row(`fee_${k}`, `  ${b.actuals.find((a) => a.fees_by_kind[k])?.fees_by_kind[k]?.label ?? label(k)}`, 'Booking fee lines', (a) => dollars(a.fees_by_kind[k]?.cents ?? 0));
  row('fees', 'Total fees', 'Company fees on bookings', (a) => dollars(a.fees_cents), FMT.CUR2, true);
  sec('Paid out of rental');
  row('owner', 'Owner share of rental', 'Program and shareholder cars, by split', (a) => dollars(a.owner_share_cents));
  row('partner', 'Partner share of rental', 'Partner cars (for example 01 Motors)', (a) => dollars(a.partner_share_cents));
  row('comm', 'Staff commissions', 'Staff commissions on bookings', (a) => dollars(a.commissions_cents));
  row('kick', 'Referral kickbacks', 'Referral kickbacks on bookings', (a) => dollars(a.kickbacks_cents));
  row('ownerPaid', 'Memo: owner payouts paid in the month (cash)', 'Payouts marked paid', (a) => dollars(a.owner_payouts_paid_cents));
  row('proc', 'Payment processing fees', 'Processor fees and the processing expense category', (a) => dollars(a.processing_cents));
  sec('Expenses (Admin > Expenses), by category');
  for (const k of all((a) => a.expenses_by_category)) row(`exp_${k}`, `  ${b.actuals.find((a) => a.expenses_by_category[k])?.expenses_by_category[k]?.label ?? label(k)}`, `Category ${k}`, (a) => dollars(a.expenses_by_category[k]?.cents ?? 0));
  row('exp', 'Total expenses', 'Before HST, voided left out', (a) => dollars(a.expenses_cents), FMT.CUR2, true);
  sec('Investors');
  row('invPaid', 'Investor payouts paid', 'Payouts to investors marked paid', (a) => dollars(a.investor_payouts_cents));
  row('invIn', 'Investor capital received', 'Investments by Investment Date', (a) => dollars(a.investor_capital_cents));
  sec('Cash received by method (includes HST and deposits)');
  for (const k of all((a) => a.cash_by_method)) {
    const lbl = b.actuals.find((a) => a.cash_by_method[k])?.cash_by_method[k]?.label ?? label(k);
    row(`in_${k}`, `  ${lbl}: received`, 'Payments succeeded', (a) => dollars(a.cash_by_method[k]?.in_cents ?? 0));
    row(`out_${k}`, `  ${lbl}: refunded`, 'Refunds', (a) => dollars(a.cash_by_method[k]?.out_cents ?? 0));
  }
  r++;
  ws.put(`A${r}`, 'Latest complete month (month #)', { bold: true }).put(`C${r}`, `=MAX(C${R.flagm}:${LAST}${R.flagm})`, { fmt: FMT.INT, bold: true, bg: GREY });
  R.latest = r;
  return R;
}

// ---------------------------------------------------------------- Forecast
type FRef = Record<'k' | 'cars' | 'util' | 'rate' | 'days' | 'rental' | 'fees' | 'paid' | 'rev' | 'proc' | 'gp' | 'opex' | 'ebitda' | 'onfile' | 'inv' | 'tax' | 'ni' | 'raise' | 'one' | 'cf'
  | 'open' | 'close' | 'margin' | 'beflag' | 'be' | 'low', number> & Record<string, number | undefined>;
function forecast(wb: Workbook, b: InternalBook, A: ARef, R: RRef): FRef {
  const ws = wb.sheet(INTERNAL.f, { tab: BLACK, widths: { A: 50, B: 16, ...Object.fromEntries(cols.map((c) => [c, 13])) }, freeze: 'C7', grid: false });
  banner(ws, 1, 'CarmaCars  |  Forecast, actuals and 5 years  |  INTERNAL, DO NOT SHARE', 12, 'A = actual month (from Actuals), F = forecast from the latest complete actual month and the Assumptions. Formulas throughout.');
  const AC = q(INTERNAL.act);
  const F = {} as FRef;
  ws.put('A3', 'Month #', S.head('left')).put('B3', '5-year total / end', S.head()).put('A4', 'Month', S.head('left')).put('B4', '', { bg: RED })
    .put('A5', 'A = actual, F = forecast', S.dark('left')).put('B5', '', { bg: BLACK }).put('A6', 'Year (1 = the first 12 months)', { italic: true, color: MUTED });
  cols.forEach((c) => {
    ws.put(`${c}3`, `=${AC}${c}3`, { ...S.head(), fmt: FMT.INT }).put(`${c}4`, `=EDATE(${A.launch},${c}$3)`, { ...S.head(), fmt: FMT.MON })
      .put(`${c}5`, `=IF(AND(${AC}${c}$5=1,${c}$3<=$B$9),"A","F")`, S.dark()).put(`${c}6`, `=INT(${c}$3/12)+1`, { fmt: FMT.INT, align: 'center', color: MUTED });
  });
  // the base: the latest complete actual month and what it says
  let r = 8;
  section(ws, r++, 'Base month (from the actuals, or the assumption typed over it)', 2, RED);
  const base = (key: string, lbl: string, f: string, fmt: string) => { ws.put(`A${r}`, lbl).put(`B${r}`, f, { fmt, bold: true, bg: GREY }); F[key] = r++; };
  const at = (row: number) => `INDEX(${AC}$C$${row}:$${LAST}$${row},1,$B$9+1)`;
  base('bn', 'Base month # (-1 = no complete month yet)', `=${AC}$C$${R.latest}`, FMT.INT);
  base('bdim', 'Days in the base month', `=IF($B$9<0,30,DAY(EOMONTH(EDATE(${A.launch},$B$9),0)))`, FMT.INT);
  base('bcars', 'Cars', `=IF(ISNUMBER(${A.carsIn}),${A.carsIn},IF($B$9<0,${FALLBACK.cars},IF(N(${at(R.cars)})>0,${at(R.cars)},${FALLBACK.cars})))`, FMT.NUM);
  base('butil', 'Utilization', `=IF(ISNUMBER(${A.utilIn}),${A.utilIn},IF($B$9<0,${FALLBACK.util},IFERROR(IF(${at(R.days)}/(${at(R.cars)}*$B$10)>0,${at(R.days)}/(${at(R.cars)}*$B$10),${FALLBACK.util}),${FALLBACK.util})))`, FMT.PCT);
  base('brate', 'Revenue per rented day', `=IF(ISNUMBER(${A.rateIn}),${A.rateIn},IF($B$9<0,${FALLBACK.ratePerDay},IFERROR(IF(${at(R.rental)}/${at(R.days)}>0,${at(R.rental)}/${at(R.days)},${FALLBACK.ratePerDay}),${FALLBACK.ratePerDay})))`, FMT.CUR2);
  base('bfee', 'Fees as % of rental', `=IF(ISNUMBER(${A.feeIn}),${A.feeIn},IF($B$9<0,${FALLBACK.feePct},IFERROR(IF(${at(R.fees)}/${at(R.rental)}>0,${at(R.fees)}/${at(R.rental)},${FALLBACK.feePct}),${FALLBACK.feePct})))`, FMT.PCT);
  const out = `(${at(R.owner)}+${at(R.partner)}+${at(R.comm)}+${at(R.kick)})`;
  base('bkeep', 'Company keeps, % of rental', `=IF(ISNUMBER(${A.keepIn}),${A.keepIn},IF($B$9<0,${FALLBACK.companyKeepPct},IFERROR(IF((${at(R.rental)}-${out})/${at(R.rental)}>0,(${at(R.rental)}-${out})/${at(R.rental)},${FALLBACK.companyKeepPct}),${FALLBACK.companyKeepPct})))`, FMT.PCT);
  r++;
  const isA = (c: string) => `${c}$5="A"`;
  const k = (c: string) => `${c}$${F.k}`;
  const grow = (rate: string, c: string) => `(1+${rate})^INT(MAX(0,${k(c)}-1)/12)`;
  const grid = (key: string, lbl: string, f: (c: string, i: number) => string, fmt: string = FMT.CUR, tot: 'sum' | 'end' | null = 'sum', o: { bold?: boolean; top?: boolean; color?: string } = {}) => {
    ws.put(`A${r}`, lbl, { bold: o.bold, color: o.color });
    cols.forEach((c, i) => ws.put(`${c}${r}`, `=${f(c, i)}`, { fmt, bold: o.bold, color: o.color, border: o.top ? 'top' : undefined }));
    if (tot === 'sum') ws.put(`B${r}`, `=SUM(C${r}:${LAST}${r})`, { fmt, bold: true, bg: GREY, color: o.color });
    else if (tot === 'end') ws.put(`B${r}`, `=${LAST}${r}`, { fmt, bold: true, bg: GREY, color: o.color });
    F[key] = r++;
  };
  const gsec = (t: string) => { section(ws, r++, t, 2, RED); };
  const act = (row: number, c: string) => `${AC}${c}${row}`;
  gsec('Fleet and use');
  grid('k', 'Months after the base month', (c) => `IF($B$9<0,${c}$3+1,MAX(0,${c}$3-$B$9))`, FMT.INT, null, { color: MUTED });
  grid('cars', 'Cars', (c) => `IF(${isA(c)},${act(R.cars, c)},$B$11+${A.add}*MIN(${k(c)},${A.addMonths}))`, FMT.NUM, 'end');
  grid('util', 'Utilization', (c) => `IF(${isA(c)},IFERROR(${act(R.days, c)}/(${act(R.cars, c)}*DAY(EOMONTH(${c}$4,0))),0),$B$12+(${A.utilT}-$B$12)*MIN(1,${k(c)}/MAX(1,${A.ramp})))`, FMT.PCT, null);
  grid('rate', 'Revenue per rented day', (c) => `IF(${isA(c)},IFERROR(${act(R.rental, c)}/${act(R.days, c)},0),$B$13*${grow(A.rg, c)})`, FMT.CUR2, null);
  grid('days', 'Rented days', (c) => `IF(${isA(c)},${act(R.days, c)},${c}${F.cars}*${c}${F.util}*${DAYS_PER_MONTH})`, FMT.NUM);
  gsec('Revenue');
  grid('rental', 'Rental revenue earned', (c) => `IF(${isA(c)},${act(R.rental, c)},${c}${F.days}*${c}${F.rate})`, FMT.CUR, 'sum', { bold: true });
  grid('fees', 'Fees', (c) => `IF(${isA(c)},${act(R.fees, c)},${c}${F.rental}*$B$14)`);
  grid('paid', 'Less: owner and partner shares, commissions, kickbacks', (c) => `IF(${isA(c)},${act(R.owner, c)}+${act(R.partner, c)}+${act(R.comm, c)}+${act(R.kick, c)},${c}${F.rental}*(1-$B$15))`);
  grid('rev', 'Net revenue', (c) => `${c}${F.rental}-${c}${F.paid}+${c}${F.fees}`, FMT.CUR, 'sum', { bold: true, top: true, color: RED });
  grid('proc', 'Less: payment processing', (c) => `IF(${isA(c)},${act(R.proc, c)},(${c}${F.rental}+${c}${F.fees})*${A.proc})`);
  grid('gp', 'Gross profit', (c) => `${c}${F.rev}-${c}${F.proc}`, FMT.CUR, 'sum', { bold: true, top: true });
  gsec('Operating expenses (an actual month with nothing entered for a line uses the assumption)');
  const sumCats = (cats: readonly string[], c: string) => { const rows = cats.map((x) => R[`exp_${x}`]).filter((x): x is number => !!x); return rows.length ? rows.map((x) => `N(${act(x, c)})`).join('+') : '0'; };
  for (const l of OPEX_LINES) {
    const assumed = (c: string) => l.key === 'insurance' ? `IF(ISNUMBER(${A.premium}),${A.premium},0)/12`
      : l.key === 'staff' ? `(${A.staff}+SUMIF(${A.hireIdx},"<="&${c}$3,${A.hireAmt}))*${grow(A.cg, c)}`
      : `${A[l.key]!}*${grow(A.cg, c)}`;
    grid(`o_${l.key}`, l.label, (c) => { const s = sumCats(l.categories, c); return `IF(AND(${isA(c)},${s}>0),${s},${assumed(c)})`; });
  }
  const firstO = F[`o_${OPEX_LINES[0].key}`]!, lastO = F[`o_${OPEX_LINES[OPEX_LINES.length - 1]!.key}`]!;
  grid('opex', 'Total operating expenses', (c) => `SUM(${c}${firstO}:${c}${lastO})`, FMT.CUR, 'sum', { bold: true, top: true });
  gsec('Profit and investors');
  grid('ebitda', 'EBITDA', (c) => `${c}${F.gp}-${c}${F.opex}`, FMT.CUR, 'sum', { bold: true, color: RED });
  // investors on file: their agreements' Returns month by month (values)
  ws.put(`A${r}`, 'Investors on file: Returns (from their agreements)', { color: MUTED });
  cols.forEach((c, n) => ws.put(`${c}${r}`, investorsOnFile(b.investors, addYm(b.inputs.launchMonth, n)), { fmt: FMT.CUR, color: MUTED }));
  ws.put(`B${r}`, `=SUM(C${r}:${LAST}${r})`, { fmt: FMT.CUR, bg: GREY, color: MUTED });
  F.onfile = r++;
  grid('inv', 'Less: investor returns', (c) => `IF(${isA(c)},${act(R.invPaid, c)},${c}${F.onfile}+SUMIF(${A.raiseIdx},"<="&(${c}$3-${A.lock}-1),${A.raiseAmt})*${A.irate}/12)`);
  grid('tax', 'Less: corporate tax', (c) => `MAX(0,${c}${F.ebitda}-${c}${F.inv})*${A.tax}`);
  grid('ni', 'Net income', (c) => `${c}${F.ebitda}-${c}${F.inv}-${c}${F.tax}`, FMT.CUR, 'sum', { bold: true, top: true, color: RED });
  gsec('Cash');
  grid('raise', 'Investor capital received', (c) => `IF(${isA(c)},${act(R.invIn, c)},SUMIF(${A.raiseIdx},${c}$3,${A.raiseAmt}))`);
  grid('one', 'Less: one-time costs', (c) => `SUMIF(${A.oneIdx},${c}$3,${A.oneAmt})`);
  grid('cf', 'Net cash flow', (c) => `${c}${F.ni}+${c}${F.raise}-${c}${F.one}`, FMT.CUR, 'sum', { bold: true, top: true });
  const openRow = r, closeRow = r + 1;
  grid('open', 'Opening cash', (c, i) => (i === 0 ? A.cash0 : `${cols[i - 1]!}${closeRow}`), FMT.CUR, null);
  grid('close', 'Closing cash', (c) => `${c}${openRow}+${c}${F.cf}`, FMT.CUR, 'end', { bold: true });
  grid('margin', 'EBITDA margin', (c) => `IFERROR(${c}${F.ebitda}/${c}${F.rev},0)`, FMT.PCT, null);
  r++;
  gsec('Break-even');
  grid('beflag', 'Month # if EBITDA stays at or above zero from here', (c) => `IF(COUNTIF(${c}${F.ebitda}:$${LAST}$${F.ebitda},"<0")=0,${c}$3,9999)`, FMT.INT, null, { color: MUTED });
  ws.put(`A${r}`, 'EBITDA break-even month', { bold: true }).put(`B${r}`, `=IF(MIN(C${F.beflag}:${LAST}${F.beflag})<9999,EDATE(${A.launch},MIN(C${F.beflag}:${LAST}${F.beflag})),"Not within 5 years")`, { fmt: FMT.MON, bold: true, bg: GREY, color: RED });
  F.be = r++;
  ws.put(`A${r}`, 'Lowest closing cash', { bold: true }).put(`B${r}`, `=MIN(C${F.close}:${LAST}${F.close})`, { fmt: FMT.CUR, bold: true, bg: GREY });
  F.low = r++;
  ws.merge(`A${r + 1}:L${r + 2}`).put(`A${r + 1}`, `Formulas only past the actual months: change a blue cell on the Assumptions tab and every forecast month, the break-even and the pro forma follow. ${b.model.warnings.join(' ')}`, S.note());
  return F;
}

// ---------------------------------------------------------------- Pro forma
function proForma(wb: Workbook, F: FRef) {
  const ws = wb.sheet(INTERNAL.pf, { tab: BLACK, widths: { A: 46, B: 16, C: 16, D: 16, E: 16, F: 16, G: 16 }, freeze: 'B4', grid: false });
  banner(ws, 1, 'CarmaCars  |  Pro forma, years 1 to 5  |  INTERNAL, DO NOT SHARE', 7, 'Year 1 = the launch month and the 11 after it. Sums of the Forecast tab.');
  const FQ = q(INTERNAL.f);
  ws.put('A3', '', S.head('left'));
  for (let y = 1; y <= 5; y++) ws.put(`${colLetter(1 + y)}3`, `Year ${y}`, S.head());
  ws.put('G3', '5 years', S.head());
  const sumRow = (row: number, y: number) => `SUMIF(${FQ}$C$6:$${LAST}$6,${y},${FQ}$C$${row}:$${LAST}$${row})`;
  const endRow = (row: number, y: number) => `INDEX(${FQ}$C$${row}:$${LAST}$${row},1,${12 * y})`;
  let r = 4;
  const line = (lbl: string, row: number, o: { fmt?: string; bold?: boolean; color?: string; end?: boolean } = {}) => {
    ws.put(`A${r}`, lbl, { bold: o.bold, color: o.color });
    for (let y = 1; y <= 5; y++) ws.put(`${colLetter(1 + y)}${r}`, `=${o.end ? endRow(row, y) : sumRow(row, y)}`, { fmt: o.fmt ?? FMT.CUR, bold: o.bold, color: o.color, border: 'box' });
    ws.put(`G${r}`, o.end ? `=F${r}` : `=SUM(B${r}:F${r})`, { fmt: o.fmt ?? FMT.CUR, bold: true, bg: GREY, color: o.color, border: 'box' });
    r++;
  };
  const sec = (t: string) => { section(ws, r++, t, 7, RED); };
  sec('Income statement');
  line('Rental revenue earned', F.rental!);
  line('Fees', F.fees!);
  line('Less: owner and partner shares, commissions, kickbacks', F.paid!);
  line('Net revenue', F.rev!, { bold: true });
  line('Less: payment processing', F.proc!);
  line('Gross profit', F.gp!, { bold: true });
  line('Operating expenses', F.opex!);
  line('EBITDA', F.ebitda!, { bold: true, color: RED });
  line('Investor returns', F.inv!);
  line('Corporate tax', F.tax!);
  line('Net income', F.ni!, { bold: true, color: RED });
  r++;
  sec('Cash flow');
  line('Investor capital received', F.raise!);
  line('One-time costs', F.one!);
  line('Net cash flow', F.cf!, { bold: true });
  line('Closing cash (end of year)', F.close!, { bold: true, end: true });
  r++;
  sec('Key figures');
  line('Cars at year end', F.cars!, { fmt: FMT.NUM, end: true });
  line('Rented days', F.days!, { fmt: FMT.NUM });
  const ratio = (lbl: string, num: number, den: number, fmt: string) => {
    ws.put(`A${r}`, lbl);
    for (const c of ['B', 'C', 'D', 'E', 'F', 'G']) ws.put(`${c}${r}`, `=IFERROR(${c}${num}/${c}${den},0)`, { fmt, border: 'box', bg: c === 'G' ? GREY : undefined });
    r++;
  };
  const rowOf = (lbl: string) => { for (let x = 4; x < r; x++) if ((ws.get(`A${x}`)?.v ?? '') === lbl) return x; return 4; };
  ratio('EBITDA margin (EBITDA / net revenue)', rowOf('EBITDA'), rowOf('Net revenue'), FMT.PCT);
  ratio('Investor coverage (EBITDA / investor returns)', rowOf('EBITDA'), rowOf('Investor returns'), FMT.MULT);
  ratio('Revenue per rented day', rowOf('Rental revenue earned'), rowOf('Rented days'), FMT.CUR2);
  r++;
  ws.merge(`A${r}:G${r + 1}`).put(`A${r}`, 'Internal planning figures, not audited and not a forecast to share. Every year sums the Forecast tab, which runs from the actuals and the Assumptions tab.', S.note());
}

