'use client';
import { useId, useMemo, useState } from 'react';
import { money } from '@/lib/format';
import { computeReturns, longDate, monthLabel, shortMonth } from './returns';
import { LineChart } from './Charts';

// The return calculator (the owner's request of October 21, 2026): the Investment Agreement's rules (./returns.ts),
// in the browser. Amount (at least the minimum), paid monthly or reinvested (or reinvested, then paid), 1 to 10 years.
type Mode = 'pay' | 'reinvest' | 'switch';
const c = (n: number) => money(n, { cents: true });

export function ReturnsCalculator({ yearlyBps, minCents, lockupMonths, paymentDay, defaultDate }: {
  yearlyBps: number; minCents: number; lockupMonths: number; paymentDay: number; defaultDate: string;
}) {
  const id = useId().replace(/:/g, '');
  const [amount, setAmount] = useState(String(Math.round(minCents / 100)));
  const [mode, setMode] = useState<Mode>('pay');
  const [years, setYears] = useState(3);
  const [switchAfter, setSwitchAfter] = useState(1);
  const [date, setDate] = useState(defaultDate);
  const cents = Math.round(Number(amount.replace(/[$,\s]/g, '')) * 100);
  const valid = Number.isFinite(cents) && cents >= minCents && cents <= 1_000_000_000 && /^\d{4}-\d{2}-\d{2}$/.test(date);
  const sw = Math.min(switchAfter, Math.max(1, years - 1));
  const r = useMemo(() => valid ? computeReturns({ amountCents: cents, yearlyBps, investmentDate: date, years, lockupMonths, paymentDay,
    reinvestMonths: mode === 'pay' ? 0 : mode === 'reinvest' ? Infinity : sw * 12 }) : null, [valid, cents, yearlyBps, date, years, lockupMonths, paymentDay, mode, sw]);

  // the chart: month 0 is the Investment Date; the lockup months are flat
  const chart = useMemo(() => {
    if (!r) return null;
    const m0 = r.months[0]; const lock = m0 ? (Number(m0.month.slice(0, 4)) * 12 + Number(m0.month.slice(5, 7))) - (Number(date.slice(0, 4)) * 12 + Number(date.slice(5, 7))) : 0;
    const inv: number[] = [], got: number[] = [], labels: string[] = [];
    for (let k = 0; k <= lock; k++) { inv.push(cents); got.push(cents); labels.push(k === 0 ? 'Start' : ''); }
    let paid = 0;
    for (const m of r.months) { if (m.mode === 'pay') paid += m.returnCents; inv.push(m.closingCents); got.push(m.closingCents + paid); labels.push(shortMonth(m.month)); }
    return { inv, got, labels, lock };
  }, [r, cents, date]);

  return (
    <div className="dk-calc" data-testid="deck-calculator">
      <form className="dk-calc__form" onSubmit={(e) => e.preventDefault()} aria-describedby={`${id}-rules`}>
        <div className="field">
          <label className="label" htmlFor={`${id}-amt`}>Amount ($)</label>
          <input className="input" id={`${id}-amt`} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} aria-invalid={!valid || undefined} data-testid="calc-amount" />
          {!valid && <p className="error" role="alert">At least {money(minCents)}, and a valid date.</p>}
        </div>
        <div className="field">
          <span className="label" id={`${id}-m`}>Returns</span>
          <div className="dk-seg" role="group" aria-labelledby={`${id}-m`}>
            {([['pay', 'Paid monthly'], ['reinvest', 'Reinvested'], ['switch', 'Reinvest, then paid']] as const).map(([v, l]) =>
              <button key={v} type="button" aria-pressed={mode === v} onClick={() => setMode(v)} data-testid={`calc-mode-${v}`}>{l}</button>)}
          </div>
        </div>
        <div className="field">
          <label className="label" htmlFor={`${id}-y`}>Years shown</label>
          <select className="select" id={`${id}-y`} value={years} onChange={(e) => setYears(Number(e.target.value))} data-testid="calc-years">
            {Array.from({ length: 10 }, (_, k) => k + 1).map((y) => <option key={y} value={y}>{y} {y === 1 ? 'year' : 'years'}</option>)}
          </select>
        </div>
        {mode === 'switch' && <div className="field">
          <label className="label" htmlFor={`${id}-s`}>Switch to paid after</label>
          <select className="select" id={`${id}-s`} value={sw} onChange={(e) => setSwitchAfter(Number(e.target.value))} disabled={years < 2}>
            {Array.from({ length: Math.max(1, years - 1) }, (_, k) => k + 1).map((y) => <option key={y} value={y}>{y} {y === 1 ? 'year' : 'years'} of Returns</option>)}
          </select>
        </div>}
        <div className="field">
          <label className="label" htmlFor={`${id}-d`}>Investment Date</label>
          <input className="input" id={`${id}-d`} type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </div>
      </form>
      <p className="dk-note" id={`${id}-rules`}>At {(yearlyBps / 100).toFixed(yearlyBps % 100 ? 2 : 0)}% a year. No Return for the {lockupMonths}-month lockup. Then each month earns one twelfth of the yearly percentage on the Invested Amount, by days for a part month, paid on the {paymentDay}th of the next month or added to the Invested Amount at month end. Illustration only.</p>
      {r && chart && <>
        <div className="dk-calc__out" aria-live="polite" data-testid="calc-out">
          <div className="dk-card"><div className="dk-stat"><span>Lockup ends</span><b className="num">{longDate(r.lockupEndDate)}</b></div></div>
          <div className="dk-card"><div className="dk-stat"><span>First payment</span><b className="num" data-testid="calc-first">{r.firstPaymentDate ? longDate(r.firstPaymentDate) : 'None in this period'}</b>
            {r.monthsToFirstPayment !== null && <span>about {r.monthsToFirstPayment} months after you invest</span>}</div></div>
          <div className="dk-card"><div className="dk-stat"><span>A full month pays</span><b className="num" data-testid="calc-monthly">{r.monthlyPaymentCents !== null ? c(r.monthlyPaymentCents) : 'Reinvested'}</b></div></div>
          <div className="dk-card"><div className="dk-stat"><span>Paid to you for the period</span><b className="num" data-testid="calc-paid">{c(r.totalPaidCents)}</b></div></div>
          <div className="dk-card dk-card--accent"><div className="dk-stat"><span>Invested Amount on {longDate(r.endDate)}</span><b className="num" data-testid="calc-value">{c(r.finalInvestedCents)}</b></div></div>
        </div>
        <div className="dk-calc__chart">
          <LineChart title={`${money(cents)} at ${yearlyBps / 100}% a year: Invested Amount and money received`} labels={chart.labels} lockupMonths={chart.lock} floor={cents} height={240}
            series={[{ name: 'Invested Amount plus Returns paid to you', color: '#D0111B', values: chart.got }, { name: 'Invested Amount', color: '#000000', dash: true, values: chart.inv }]} />
          <p className="dk-legend"><span><i style={{ background: '#D0111B' }} />Invested Amount plus Returns paid to you</span><span><i style={{ background: '#000' }} />Invested Amount</span><span><i style={{ background: '#F0F0F0', border: '1px solid #ccc' }} />Lockup</span></p>
        </div>
        <details className="dk-screen-only" open>
          <summary className="strong">Month by month ({r.months.length} Return Months)</summary>
          <div className="dk-calc__table" tabIndex={0} role="region" aria-label="Month by month">
            <table className="dk-tbl" data-testid="calc-table">
              <thead><tr><th>#</th><th>Return Month</th><th className="n">Days</th><th className="n">Invested at start</th><th className="n">Return</th><th>How</th><th className="n">Invested at end</th></tr></thead>
              <tbody>{r.months.map((m) => <tr key={m.n}><td>{m.n}</td><td>{monthLabel(m.month)}</td><td className="n">{m.daysEarning === m.daysInMonth ? 'full' : `${m.daysEarning} of ${m.daysInMonth}`}</td>
                <td className="n">{c(m.openingCents)}</td><td className="n">{c(m.returnCents)}</td><td>{m.mode === 'pay' ? `Paid ${m.paymentDate ? longDate(m.paymentDate) : ''}` : 'Reinvested'}</td><td className="n">{c(m.closingCents)}</td></tr>)}</tbody>
            </table>
          </div>
        </details>
      </>}
    </div>
  );
}
