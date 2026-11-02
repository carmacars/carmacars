'use client';
import { useId, useMemo, useState } from 'react';
import { DateInput } from '@/components/DateInput';
import { money } from '@/lib/format';
import { BLANK_CAR, CAR_DEFAULTS, carPayoutSchedule, fundCars, investmentCalc, type CarInputs } from './calc';
import { longDate, monthLabel } from '../deck/returns';

// The two interactive sheets of the investor portal's Model page, in the browser: the workbook's "Investment calculator"
// and "Fund a car (owner program)" (./calc.ts has the formulas). Nothing is sent anywhere; the download writes the same
// sheets with the same formulas.
const $ = (dollars: number) => money(Math.round(dollars * 100), { cents: true });
const $0 = (dollars: number) => money(Math.round(dollars) * 100);
const pct = (f: number) => `${+(f * 100).toFixed(2)}%`;
const num = (s: string) => Number(String(s).replace(/[$,%\s]/g, ''));

export function InvestmentCalculator({ amount, start, rate, lockupMonths, reinvest, minimum }: { amount: number; start: string; rate: number; lockupMonths: number; reinvest: boolean; minimum: number }) {
  const id = useId().replace(/:/g, '');
  const [amt, setAmt] = useState(String(amount));
  const [date, setDate] = useState(start);
  const [r, setR] = useState(String(+(rate * 100).toFixed(2)));
  const [re, setRe] = useState(reinvest);
  const a = num(amt), rr = num(r) / 100;
  const ok = Number.isFinite(a) && a > 0 && a <= 100_000_000 && /^\d{4}-\d{2}-\d{2}$/.test(date) && Number.isFinite(rr) && rr >= 0 && rr <= 1;
  const res = useMemo(() => (ok ? investmentCalc({ amount: a, start: date, rate: rr, lockupMonths, reinvest: re }, minimum) : null), [ok, a, date, rr, lockupMonths, re, minimum]);
  return (
    <div className="im-calc" data-testid="model-calculator">
      <form className="pu-panel im-inputs" onSubmit={(e) => e.preventDefault()} aria-labelledby={`${id}-h`}>
        <h2 className="pu-title" id={`${id}-h`}>Your inputs</h2>
        <div className="im-fields">
          <div className="field">
            <label className="label" htmlFor={`${id}-a`}>Amount invested ($)</label>
            <input className="input" id={`${id}-a`} inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} aria-describedby={`${id}-am`} data-testid="calc-amount" />
            <p className={`small${res?.belowMinimum ? ' im-warn' : ' muted'}`} id={`${id}-am`} role={res?.belowMinimum ? 'alert' : undefined}>{res?.belowMinimum ? `Below the ${$0(minimum)} minimum.` : `Minimum ${$0(minimum)}.`}</p>
          </div>
          <div className="field">
            <label className="label" htmlFor={`${id}-d`}>Start date (funds received)</label>
            <DateInput className="input" id={`${id}-d`} value={date} onChange={(e) => setDate(e.target.value)} data-testid="calc-start" />
          </div>
          <div className="field">
            <label className="label" htmlFor={`${id}-r`}>Annual return (%)</label>
            <input className="input" id={`${id}-r`} inputMode="decimal" value={r} onChange={(e) => setR(e.target.value)} aria-describedby={`${id}-rm`} data-testid="calc-rate" />
            <p className="small muted" id={`${id}-rm`}>Set in each investor&apos;s own agreement.</p>
          </div>
          <div className="field">
            <span className="label" id={`${id}-m`}>Your returns</span>
            <div className="pu-seg" role="group" aria-labelledby={`${id}-m`}>
              <button type="button" aria-pressed={!re} onClick={() => setRe(false)} data-testid="calc-paid">Paid monthly</button>
              <button type="button" aria-pressed={re} onClick={() => setRe(true)} data-testid="calc-reinvest">Reinvested</button>
            </div>
          </div>
        </div>
        <p className="small muted">No return accrues for the {lockupMonths}-month lockup. After it, each month earns one twelfth of the yearly return on the balance; reinvested, it is added to the balance and earns from the next month.</p>
      </form>
      {res ? <>
        <div className="im-stats" aria-live="polite" data-testid="calc-results">
          <div className="im-stat im-stat--accent"><span>Monthly payout to you</span><b data-testid="calc-monthly">{$(res.monthlyPayout)}</b><small>{re ? 'Reinvested, so nothing paid out' : `from month ${lockupMonths + 1}`}</small></div>
          <div className="im-stat"><span>Lockup ends</span><b>{longDate(res.lockupEnds)}</b><small>First payment {longDate(res.firstPayment)}</small></div>
          <div className="im-stat"><span>Paid to you by month 36</span><b data-testid="calc-paid36">{$0(res.paidBy36)}</b><small>{$0(res.paidBy24)} by month 24</small></div>
          <div className="im-stat"><span>Value at month 36</span><b data-testid="calc-value">{$0(res.value36)}</b><small>{res.multiple36.toFixed(2)}x the amount invested</small></div>
        </div>
        <section className="pu-panel" aria-labelledby={`${id}-s`}>
          <div className="im-head"><h2 className="pu-title" id={`${id}-s`}>Payout schedule, 36 months</h2><span className="small muted">Months 24 and 36 highlighted</span></div>
          <div className="im-scroll" tabIndex={0} role="region" aria-label="Payout schedule, 36 months">
            <table className="im-table" data-testid="calc-table">
              <thead><tr><th scope="col">Month</th><th scope="col">Payment date</th><th scope="col">Phase</th><th scope="col" className="num">Balance at start</th><th scope="col" className="num">Return earned</th><th scope="col" className="num">Paid to you</th><th scope="col" className="num">Cumulative paid</th><th scope="col" className="num">Balance at end</th></tr></thead>
              <tbody>{res.rows.map((x) => (
                <tr key={x.n} className={x.n === 24 || x.n === 36 ? 'is-mark' : x.phase === 'Lockup' ? 'is-lock' : undefined}>
                  <td>{x.n}</td><td>{longDate(x.date)}</td><td>{x.phase}</td><td className="num">{$0(x.balanceStart)}</td><td className="num">{$(x.earned)}</td><td className="num">{$(x.paid)}</td><td className="num">{$0(x.cumPaid)}</td><td className="num">{$0(x.balanceEnd)}</td>
                </tr>))}</tbody>
            </table>
          </div>
          <p className="small muted">Illustration only. Payment dates are shown one calendar month apart from the start date; your agreement sets the actual payment day. The signed investment agreement governs.</p>
        </section>
      </> : <p className="error" role="alert">Enter an amount, a start date and a yearly percentage between 0 and 100.</p>}
    </div>
  );
}

const CAR_FIELDS: Array<{ k: keyof CarInputs; label: string; unit: '$' | '%' | 'days' | 'text'; hint?: string }> = [
  { k: 'name', label: 'Car (make, model, year)', unit: 'text' },
  { k: 'price', label: 'Purchase price ($)', unit: '$' },
  { k: 'dailyRate', label: 'Daily rate charged to renters ($)', unit: '$' },
  { k: 'daysPerMonth', label: 'Rented days per month (your estimate)', unit: 'days', hint: 'You are not paid for downtime.' },
  { k: 'ownerShare', label: 'Your share of rental revenue (%)', unit: '%', hint: 'Your owner agreement sets your actual share.' },
  { k: 'commissions', label: 'Booking commissions before the split (%)', unit: '%' },
  { k: 'insuranceFee', label: 'Monthly insurance fee ($)', unit: '$', hint: 'Per your agreement.' },
  { k: 'trackerFee', label: 'Monthly tracker fee ($)', unit: '$', hint: 'Per your agreement.' },
  { k: 'depreciation', label: 'Depreciation per year (%)', unit: '%', hint: 'Used cars typically lose about 10% to 20% a year.' }
];
type Draft = Record<keyof CarInputs, string>;
const toDraft = (c: CarInputs): Draft => Object.fromEntries(CAR_FIELDS.map((f) => [f.k, f.unit === 'text' ? String(c[f.k]) : f.unit === '%' ? String(+(Number(c[f.k]) * 100).toFixed(2)) : String(c[f.k])])) as Draft;
const fromDraft = (d: Draft): CarInputs => Object.fromEntries(CAR_FIELDS.map((f) => [f.k, f.unit === 'text' ? d[f.k] : f.unit === '%' ? (num(d[f.k]) || 0) / 100 : num(d[f.k]) || 0])) as unknown as CarInputs;

export function FundACar({ firstMonth }: { firstMonth: string }) {
  const id = useId().replace(/:/g, '');
  const [cars, setCars] = useState<Draft[]>([toDraft(CAR_DEFAULTS)]);
  const [open, setOpen] = useState(0);
  const parsed = cars.map(fromDraft);
  const { each, total } = fundCars(parsed);
  const sched = carPayoutSchedule(firstMonth, total.cash);
  const set = (i: number, k: keyof CarInputs, v: string) => setCars((cs) => cs.map((c, j) => (j === i ? { ...c, [k]: v } : c)));
  const rows: Array<[string, (r: (typeof each)[number] | typeof total) => string, boolean?]> = [
    ['Rental revenue', (r) => $0(r.gross)], ['Less: booking commissions', (r) => $0(r.commissions)], ['Less: CarmaCars share', (r) => $0(r.company)],
    ['Your share of rental revenue', (r) => $0(r.ownerShare), true], ['Less: insurance fee', (r) => $0(r.insurance)], ['Less: tracker fee', (r) => $0(r.tracker)],
    ['Your monthly payout (cash)', (r) => $0(r.cash), true], ['Less: depreciation (not cash)', (r) => $0(r.depreciation)], ['Your monthly net after depreciation', (r) => $0(r.net), true],
    ['Yearly payout (cash)', (r) => $0(r.yearlyCash), true], ['Yearly net after depreciation', (r) => $0(r.yearlyNet)],
    ['ROI per year (net / price)', (r) => pct(r.roi), true], ['Cash yield per year (payout / price)', (r) => pct(r.cashYield)],
    ['Payback on cash payouts (months)', (r) => (r.paybackMonths === null ? 'n/a' : r.paybackMonths.toFixed(1))], ['Upfront at signing: first and last month fees', (r) => $0(r.upfront)]
  ];
  return (
    <div className="im-car" data-testid="model-fund-car">
      <div className="pu-panel">
        <div className="im-head">
          <h2 className="pu-title">Your cars</h2>
          {cars.length > 1 && <div className="pu-seg" role="group" aria-label="Car to edit">
            {cars.map((_, i) => <button key={i} type="button" aria-pressed={open === i} onClick={() => setOpen(i)}>Car {i + 1}</button>)}
          </div>}
        </div>
        <div className="im-fields im-fields--car">
          {CAR_FIELDS.map((f) => (
            <div className="field" key={f.k}>
              <label className="label" htmlFor={`${id}-${f.k}`}>{f.label}</label>
              <input className="input" id={`${id}-${f.k}`} inputMode={f.unit === 'text' ? 'text' : 'decimal'} value={cars[open]?.[f.k] ?? ''} onChange={(e) => set(open, f.k, e.target.value)}
                aria-describedby={f.hint ? `${id}-${f.k}-h` : undefined} data-testid={`car-${f.k}`} />
              {f.hint && <p className="small muted" id={`${id}-${f.k}-h`}>{f.hint}</p>}
            </div>
          ))}
        </div>
        <div className="im-actions">
          {cars.length < 3 && <button type="button" className="btn btn--ghost btn--sm" onClick={() => { setCars((c) => [...c, toDraft({ ...BLANK_CAR, name: `Car ${c.length + 1}` })]); setOpen(cars.length); }} data-testid="car-add">Add a car</button>}
          {cars.length > 1 && <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setCars((c) => c.filter((_, j) => j !== open)); setOpen(0); }}>Remove car {open + 1}</button>}
        </div>
      </div>
      <div className="im-stats" aria-live="polite">
        <div className="im-stat im-stat--accent"><span>Your monthly payout</span><b data-testid="car-cash">{$0(total.cash)}</b><small>{cars.length > 1 ? `${cars.length} cars together` : 'Paid on the 10th for last month'}</small></div>
        <div className="im-stat"><span>Yearly payout</span><b>{$0(total.yearlyCash)}</b><small>{$0(total.yearlyNet)} after depreciation</small></div>
        <div className="im-stat"><span>ROI per year</span><b>{pct(total.roi)}</b><small>Net after depreciation over the price</small></div>
        <div className="im-stat"><span>Payback</span><b>{total.paybackMonths === null ? 'n/a' : `${total.paybackMonths.toFixed(1)} months`}</b><small>On cash payouts</small></div>
      </div>
      <section className="pu-panel" aria-labelledby={`${id}-t`}>
        <h2 className="pu-title" id={`${id}-t`}>Month by month</h2>
        <div className="im-scroll" tabIndex={0} role="region" aria-label="Fund a car, month by month">
          <table className="im-table im-table--lines">
            <thead><tr><th scope="col">Line</th>{parsed.map((c, i) => <th key={i} scope="col" className="num">{c.name || `Car ${i + 1}`}</th>)}{parsed.length > 1 && <th scope="col" className="num">All cars</th>}</tr></thead>
            <tbody>{rows.map(([l, f, strong]) => (
              <tr key={l} className={strong ? 'is-strong' : undefined}><th scope="row">{l}</th>{each.map((r, i) => <td key={i} className="num">{f(r)}</td>)}{parsed.length > 1 && <td className="num">{f(total)}</td>}</tr>))}</tbody>
          </table>
        </div>
      </section>
      <section className="pu-panel" aria-labelledby={`${id}-p`}>
        <h2 className="pu-title" id={`${id}-p`}>Payout schedule, 12 months</h2>
        <div className="im-scroll" tabIndex={0} role="region" aria-label="Payout schedule, 12 months">
          <table className="im-table">
            <thead><tr><th scope="col">Revenue month</th><th scope="col">Paid on</th><th scope="col" className="num">Payout</th><th scope="col" className="num">Cumulative</th></tr></thead>
            <tbody>{sched.map((s) => <tr key={s.month}><td>{monthLabel(s.month)}</td><td>{longDate(s.paidOn)}</td><td className="num">{$0(s.payout)}</td><td className="num">{$0(s.cumulative)}</td></tr>)}</tbody>
          </table>
        </div>
        <p className="small muted">Illustration only, from your own inputs. Owners are paid monthly on the 10th for the previous month&apos;s rentals, only for days the car is rented. Your signed owner agreement sets your actual share and fees; owners sign owner agreements, not investment agreements.</p>
      </section>
    </div>
  );
}
