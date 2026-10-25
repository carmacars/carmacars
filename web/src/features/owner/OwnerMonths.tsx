'use client';
import Link from 'next/link';
import { useMemo, useState } from 'react';
import { money, plural } from '@/lib/format';
import { BarChart, MoneySummary, PuIcon } from '@/components/portal-ui';
import type { MonthStat } from './insights';

type View = 'rental' | 'payout';

/**
 * The owner's months: a column per month (rental charges or payouts), a month switcher, and the chosen month per car.
 * With one car (`only`) it is that car's drilldown. Every figure is the owner's own (insights.ts).
 */
export function OwnerMonths({ months, only, testId = 'owner-months' }: { months: MonthStat[]; only?: string; testId?: string }) {
  const [sel, setSel] = useState(() => months.find((m) => m.current)?.key ?? months[months.length - 1]?.key ?? '');
  const [car, setCar] = useState<string>(only ?? 'all');
  const [view, setView] = useState<View>('rental');
  const cars = months[0]?.cars ?? [];
  const idx = months.findIndex((m) => m.key === sel);
  const m = months[idx];
  const pick = (x: MonthStat) => (car === 'all' ? { bookings: x.bookings, days: x.days, rental_cents: x.rental_cents, fees_cents: x.fees_cents } : x.cars.find((c) => c.vehicle_id === car) ?? { bookings: 0, days: 0, rental_cents: 0, fees_cents: 0 });
  const payouts = view === 'payout' && car === 'all';
  const bars = useMemo(() => months.map((x) => {
    const v = payouts ? x.payout_cents ?? 0 : pick(x).rental_cents;
    return { key: x.key, label: x.label, short: x.short, value: v, display: payouts && x.payout_cents === null ? 'No statement' : money(v) };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }), [months, car, payouts]);
  if (!m) return null;
  const s = pick(m);
  const carName = cars.find((c) => c.vehicle_id === car)?.name;
  return (
    <section className="pu-panel ow-months" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <div className="pu-panel__head">
        <div><p className="pu-eyebrow">{only ? 'This car by month' : 'Your earnings'}</p><h2 className="pu-title" id={`${testId}-h`}>{payouts ? 'Payouts by month' : `Rental charges by month${carName && !only ? `: ${carName}` : ''}`}</h2></div>
        {!only && <div className="pu-seg" role="group" aria-label="What the chart shows">
          <button type="button" aria-pressed={view === 'rental'} onClick={() => setView('rental')}>Rental charges</button>
          <button type="button" aria-pressed={view === 'payout'} onClick={() => { setView('payout'); setCar('all'); }} data-testid="months-payouts">Payouts</button>
        </div>}
      </div>
      {!only && cars.length > 1 && view === 'rental' && (
        <div className="pu-seg ow-months__cars" role="group" aria-label="Which car">
          <button type="button" aria-pressed={car === 'all'} onClick={() => setCar('all')}>All cars</button>
          {cars.map((c) => <button key={c.vehicle_id} type="button" aria-pressed={car === c.vehicle_id} onClick={() => setCar(c.vehicle_id)} data-testid="months-car">{c.name}</button>)}
        </div>
      )}
      <BarChart bars={bars} title={payouts ? 'Payouts by month' : 'Rental charges by month'} selected={sel} onSelect={setSel} testId="months-chart" />
      <div className="ow-months__head">
        <div className="pu-stepper">
          <button type="button" onClick={() => setSel(months[idx - 1]!.key)} disabled={idx <= 0} aria-label="Earlier month"><PuIcon name="left" /></button>
          <output aria-live="polite" data-testid="months-current">{m.label}</output>
          <button type="button" onClick={() => setSel(months[idx + 1]!.key)} disabled={idx >= months.length - 1} aria-label="Later month"><PuIcon name="right" /></button>
        </div>
        {m.current && <span className="pu-pill pu-pill--accent">So far this month</span>}
      </div>
      <MoneySummary label={`${m.label}${carName ? `, ${carName}` : ''}`} rows={[
        { label: 'Bookings', value: s.bookings, testId: 'months-bookings' },
        { label: 'Days rented', value: plural(s.days, 'day'), testId: 'months-days' },
        { label: 'Rental charges, before tax', value: money(s.rental_cents, { cents: true }), testId: 'months-rental' },
        { label: 'Fees billed, before HST', value: money(s.fees_cents, { cents: true }), testId: 'months-fees' }
      ]} total={car === 'all' ? { label: 'Payout on the statement', testId: 'months-payout', value: m.statement_id ? <Link prefetch={false} className="link" href={`/owner/statements/${m.statement_id}`}>{money(m.payout_cents, { cents: true })}</Link> : m.current ? 'After the month ends' : 'No statement' } : undefined} />
      {m.held > 0 && <p className="small muted" data-testid="months-held">{m.held === 1 ? 'One more booking' : `${m.held} more bookings`} this month will show {m.held === 1 ? 'its' : 'their'} figures once CarmaCars approves the statement that covers {m.held === 1 ? 'it' : 'them'}. Your statement always includes every booking.</p>}
      {!only && car === 'all' && cars.length > 1 && (
        <div className="ow-months__table" role="region" aria-label={`Each car in ${m.label}`}>
          <table className="pu-table">
            <thead><tr><th scope="col">Car</th><th scope="col" className="num">Days</th><th scope="col" className="num">Bookings</th><th scope="col" className="num">Rental charges</th><th scope="col" className="num">Fees</th></tr></thead>
            <tbody>{m.cars.map((c) => (
              <tr key={c.vehicle_id}>
                <th scope="row" data-label="Car"><button type="button" className="ow-months__car" onClick={() => setCar(c.vehicle_id)}>{c.name}</button></th>
                <td className="num" data-label="Days">{c.days}</td><td className="num" data-label="Bookings">{c.bookings}</td>
                <td className="num" data-label="Rental charges">{money(c.rental_cents, { cents: true })}</td><td className="num" data-label="Fees">{money(c.fees_cents, { cents: true })}</td>
              </tr>))}</tbody>
          </table>
        </div>
      )}
      <p className="pu-chart__cap">Rental charges are before tax and after discounts, counted by rental day, so a rental over two months counts in each. Your monthly statement has the final numbers.</p>
    </section>
  );
}
