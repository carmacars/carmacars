import { PageHead, Tabs } from '@/features/admin/ui';
import { ModelChart } from './Chart';
import { AssumptionsForm } from './AssumptionsForm';
import { OPEX_LINES, type ActualMonth, type Inputs, type Model, type ModelMonth } from './engine';
import type { FinanceRead } from '@/server/finance-model';
import type { ReactNode } from 'react';

const base = '/admin/money/model';
const $ = (v: number) => `${v < 0 ? '-' : ''}$${Math.abs(Math.round(v)).toLocaleString('en-CA')}`;
const $c = (cents: number) => $(cents / 100);
const pct = (f: number) => `${(f * 100).toFixed(1)}%`;
const mon = (m: string) => new Date(`${m.slice(0, 7)}-15T12:00:00Z`).toLocaleDateString('en-CA', { month: 'short', year: 'numeric', timeZone: 'UTC' });
const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : 'not yet');

type Line = { label: string; v: (m: ModelMonth) => string; strong?: boolean; neg?: (m: ModelMonth) => boolean; est?: (m: ModelMonth) => boolean } | { section: string };

// Admin > Money > Company model, laid out (app/admin/money/model/page.tsx loads it and passes the header's buttons).
export function CompanyModelView({ read, inputs, model, tab: asked, actions }: { read: FinanceRead; inputs: Inputs; model: Model; tab: string | undefined; actions: ReactNode }) {
  const tab = ['forecast', 'actuals', 'proforma', 'assumptions'].includes(asked ?? '') ? asked! : 'forecast';
  const tabs = <Tabs current={`${base}?tab=${tab}`} label="Company model" items={[[`${base}?tab=forecast`, 'Forecast'], [`${base}?tab=actuals`, 'Actuals'], [`${base}?tab=proforma`, 'Pro forma 5 years'], [`${base}?tab=assumptions`, 'Assumptions']]} />;
  const m36 = model.months.slice(0, 36);
  const next12 = model.months.filter((m) => m.kind === 'F').slice(0, 12);
  const sum = (xs: ModelMonth[], f: (m: ModelMonth) => number) => xs.reduce((s, m) => s + f(m), 0);
  const latest = model.latestActual;
  const head = (
    <PageHead title="Company model" kicker="Money, internal: do not share" purpose={`Actuals fill themselves from the database each hour (last ${when(read.computed_at)}). The forecast runs from ${latest ? mon(latest) : 'the assumptions (no complete month yet)'} and the assumptions below.`}>
      {actions}
    </PageHead>
  );
  const tiles = (
    <div className="im-stats" data-testid="model-tiles">
      <div className="im-stat im-stat--ink"><span>Latest actual month</span><b>{latest ? mon(latest) : 'None yet'}</b><small>{latest ? `${$(model.months.find((m) => m.month === latest)?.rental ?? 0)} rental earned` : 'The first month completes at its end'}</small></div>
      <div className={`im-stat${model.breakEven ? ' im-stat--accent' : ' im-stat--bad'}`}><span>EBITDA break-even</span><b data-testid="model-breakeven">{model.breakEven ? mon(model.breakEven) : 'Not within 5 years'}</b><small>EBITDA stays at or above zero from then</small></div>
      <div className="im-stat"><span>EBITDA, next 12 months</span><b>{$(sum(next12, (m) => m.ebitda))}</b><small>{pct(sum(next12, (m) => m.netRevenue) ? sum(next12, (m) => m.ebitda) / sum(next12, (m) => m.netRevenue) : 0)} of net revenue</small></div>
      <div className={`im-stat${model.cashLow && model.cashLow.cash < 0 ? ' im-stat--bad' : ''}`}><span>Lowest cash</span><b>{model.cashLow ? $(model.cashLow.cash) : 'n/a'}</b><small>{model.cashLow ? mon(model.cashLow.month) : ''}</small></div>
    </div>
  );
  const warnings = model.warnings.length ? <ul className="im-warnings" data-testid="model-warnings">{model.warnings.map((w) => <li key={w}>{w}</li>)}</ul> : null;

  if (tab === 'assumptions') {
    const b = model.base;
    const shown: Record<string, string> = { cars: String(Math.round(b.cars)), util: pct(b.util), ratePerDay: `$${b.ratePerDay.toFixed(2)}`, feePct: pct(b.feePct), companyKeepPct: pct(b.companyKeepPct) };
    return (<>{head}{tabs}{warnings}
      <section className="pu-panel" aria-label="Assumptions">
        <p className="small muted">The forecast starts from {b.month ? mon(b.month) : 'these numbers (no complete month yet)'}: {Math.round(b.cars)} cars, {pct(b.util)} utilization, ${b.ratePerDay.toFixed(2)} per rented day, fees {pct(b.feePct)} of rental, CarmaCars keeps {pct(b.companyKeepPct)}. Type over any of them below.</p>
        <AssumptionsForm inputs={inputs} base={shown} updated={read.updated_at ? `${when(read.updated_at)}${read.updated_by ? ` by ${read.updated_by}` : ''}` : null} />
      </section></>);
  }

  if (tab === 'proforma') {
    const Y = model.years;
    const rows: Array<[string, (y: (typeof Y)[number]) => string, boolean?]> = [
      ['Rental revenue earned', (y) => $(y.rental)], ['Fees', (y) => $(y.fees)], ['Less: owner and partner shares, commissions, kickbacks', (y) => $(-y.paidOut)],
      ['Net revenue', (y) => $(y.netRevenue), true], ['Less: payment processing', (y) => $(-y.processing)], ['Gross profit', (y) => $(y.grossProfit), true],
      ['Operating expenses', (y) => $(-y.opex)], ['EBITDA', (y) => $(y.ebitda), true], ['EBITDA margin', (y) => pct(y.ebitdaMargin)],
      ['Investor returns', (y) => $(-y.investorReturns)], ['Corporate tax', (y) => $(-y.tax)], ['Net income', (y) => $(y.netIncome), true],
      ['Investor capital received', (y) => $(y.raises)], ['One-time costs', (y) => $(-y.oneTime)], ['Net cash flow', (y) => $(y.cashFlow), true], ['Closing cash', (y) => $(y.closingCash), true],
      ['Cars at year end', (y) => String(Math.round(y.carsEnd))], ['Actual months in the year', (y) => String(y.actualMonths)]
    ];
    return (<>{head}{tabs}{warnings}
      <section className="pu-panel" aria-labelledby="pf-h">
        <h2 className="pu-title" id="pf-h">Pro forma, years 1 to 5</h2>
        <div className="im-scroll" tabIndex={0} role="region" aria-label="Pro forma, years 1 to 5">
          <table className="im-table im-grid" data-testid="model-proforma">
            <thead><tr><th scope="col">Year</th>{Y.map((y) => <th key={y.year} scope="col" className="num">Year {y.year}<br /><span className="xs">{mon(y.from)} to {mon(y.to)}</span></th>)}</tr></thead>
            <tbody>{rows.map(([l, f, strong]) => <tr key={l} className={strong ? 'is-strong' : undefined}><th scope="row">{l}</th>{Y.map((y) => <td key={y.year} className="num">{f(y)}</td>)}</tr>)}</tbody>
          </table>
        </div>
        <p className="small muted">Year 1 starts in the launch month. Each year sums the months of the forecast, actual months as they happened.</p>
      </section></>);
  }

  if (tab === 'actuals') {
    const A = read.actuals;
    const keys = <K extends 'fees_by_kind' | 'expenses_by_category' | 'cash_by_method'>(k: K) => [...new Set(A.flatMap((a) => Object.keys(a[k] ?? {})))].sort();
    const lab = (k: 'fees_by_kind' | 'expenses_by_category' | 'cash_by_method', code: string) => A.find((a) => a[k]?.[code])?.[k]?.[code]?.label ?? code;
    const segs = [...new Set(A.flatMap((a) => Object.keys(a.rental_by_segment ?? {})))].sort();
    type R = { section: string } | { label: string; v: (a: ActualMonth) => string; strong?: boolean };
    const rows: R[] = [
      { section: 'Rental revenue earned (accrual by day, before HST, placeholders left out)' },
      { label: 'Total rental revenue', v: (a) => $c(a.rental_cents), strong: true }, { label: 'Insurer-billed', v: (a) => $c(a.rental_insurer_cents) }, { label: 'Renter-billed', v: (a) => $c(a.rental_renter_cents) },
      ...segs.map((s) => ({ label: `${s[0]!.toUpperCase()}${s.slice(1)} cars`, v: (a: ActualMonth) => $c(a.rental_by_segment?.[s] ?? 0) })),
      { section: 'Activity' },
      { label: 'Rented days', v: (a) => (Math.round(a.rented_days * 10) / 10).toString() }, { label: 'Rentals', v: (a) => String(a.rentals) }, { label: 'Cars on the fleet', v: (a) => String(a.cars) },
      { section: 'Fees by kind (before HST)' },
      ...keys('fees_by_kind').map((k) => ({ label: lab('fees_by_kind', k), v: (a: ActualMonth) => $c(a.fees_by_kind[k]?.cents ?? 0) })),
      { label: 'Total fees', v: (a) => $c(a.fees_cents), strong: true },
      { section: 'Paid out of rental' },
      { label: 'Owner share', v: (a) => $c(a.owner_share_cents) }, { label: 'Partner share', v: (a) => $c(a.partner_share_cents) }, { label: 'Staff commissions', v: (a) => $c(a.commissions_cents) },
      { label: 'Referral kickbacks', v: (a) => $c(a.kickbacks_cents) }, { label: 'Owner payouts paid (cash)', v: (a) => $c(a.owner_payouts_paid_cents) }, { label: 'Processing fees', v: (a) => $c(a.processing_cents) },
      { section: 'Expenses (Admin > Expenses)' },
      ...keys('expenses_by_category').map((k) => ({ label: lab('expenses_by_category', k), v: (a: ActualMonth) => $c(a.expenses_by_category[k]?.cents ?? 0) })),
      { label: 'Total expenses', v: (a) => $c(a.expenses_cents), strong: true },
      { section: 'Investors' },
      { label: 'Investor payouts paid', v: (a) => $c(a.investor_payouts_cents) }, { label: 'Investor capital received', v: (a) => $c(a.investor_capital_cents) },
      { section: 'Cash received by method (with HST and deposits)' },
      ...keys('cash_by_method').map((k) => ({ label: lab('cash_by_method', k), v: (a: ActualMonth) => { const x = a.cash_by_method[k]; return x ? `${$c(x.in_cents)}${x.out_cents ? ` (${$c(x.out_cents)} back)` : ''}` : '$0'; } }))
    ];
    const noExp = A.filter((a) => a.complete && a.expenses_cents === 0).map((a) => mon(a.month));
    return (<>{head}{tabs}
      {noExp.length > 0 && <ul className="im-warnings"><li>No expenses entered in Admin &gt; Expenses for {noExp.join(', ')}: the forecast uses the assumptions for those months&apos; costs (marked est.). Enter them in <a className="link" href="/admin/expenses">Expenses</a>.</li></ul>}
      <section className="pu-panel" aria-labelledby="ac-h">
        <h2 className="pu-title" id="ac-h">Actuals by month</h2>
        <div className="im-scroll" tabIndex={0} role="region" aria-label="Actuals by month">
          <table className="im-table im-grid" data-testid="model-actuals">
            <thead><tr><th scope="col">Month</th>{A.map((a) => <th key={a.month} scope="col" className="num">{mon(a.month)}<br /><span className={`im-pill ${a.complete ? 'is-a' : 'is-proj'}`}>{a.complete ? 'Actual' : 'So far'}</span></th>)}</tr></thead>
            <tbody>{rows.map((r, i) => 'section' in r
              ? <tr key={`s${i}`} className="is-sec"><th scope="row" colSpan={A.length + 1}>{r.section}</th></tr>
              : <tr key={r.label + i} className={r.strong ? 'is-strong' : undefined}><th scope="row">{r.label}</th>{A.map((a) => <td key={a.month} className="num">{r.v(a)}</td>)}</tr>)}</tbody>
          </table>
        </div>
        <p className="small muted">A booking&apos;s rental and fees are spread evenly over its days; each day counts in the month it starts in. Cancelled, unconfirmed and placeholder bookings are left out. The month in progress shows its figures so far.</p>
      </section></>);
  }

  const lines: Line[] = [
    { label: 'A = actual, F = forecast', v: (m) => m.kind },
    { section: 'Fleet and use' },
    { label: 'Cars', v: (m) => (Math.round(m.cars * 10) / 10).toString() }, { label: 'Utilization', v: (m) => pct(m.util) },
    { label: 'Revenue per rented day', v: (m) => `$${m.ratePerDay.toFixed(2)}` }, { label: 'Rented days', v: (m) => Math.round(m.rentedDays).toString() },
    { section: 'Revenue' },
    { label: 'Rental revenue earned', v: (m) => $(m.rental), strong: true }, { label: 'Fees', v: (m) => $(m.fees) }, { label: 'Less: shares, commissions, kickbacks', v: (m) => $(-m.paidOut) },
    { label: 'Net revenue', v: (m) => $(m.netRevenue), strong: true }, { label: 'Less: payment processing', v: (m) => $(-m.processing) }, { label: 'Gross profit', v: (m) => $(m.grossProfit), strong: true },
    { section: 'Operating expenses' },
    ...OPEX_LINES.map((l) => ({ label: l.label, v: (m: ModelMonth) => $(-m.opex[l.key]), est: (m: ModelMonth) => m.opexEstimated.includes(l.key) })),
    { label: 'Total operating expenses', v: (m) => $(-m.opexTotal), strong: true },
    { section: 'Profit and cash' },
    { label: 'EBITDA', v: (m) => $(m.ebitda), strong: true, neg: (m) => m.ebitda < 0 }, { label: 'Less: investor returns', v: (m) => $(-m.investorReturns) }, { label: 'Less: corporate tax', v: (m) => $(-m.tax) },
    { label: 'Net income', v: (m) => $(m.netIncome), strong: true, neg: (m) => m.netIncome < 0 }, { label: 'Investor capital received', v: (m) => $(m.raises) }, { label: 'Less: one-time costs', v: (m) => $(-m.oneTime) },
    { label: 'Net cash flow', v: (m) => $(m.cashFlow) }, { label: 'Closing cash', v: (m) => $(m.closingCash), strong: true, neg: (m) => m.closingCash < 0 }
  ];
  return (<>{head}{tabs}{warnings}{tiles}
    <section className="pu-panel" aria-labelledby="fc-c">
      <h2 className="pu-title" id="fc-c">EBITDA and cash, 36 months</h2>
      <ModelChart months={m36} title="EBITDA by month, actual and forecast, with closing cash" />
    </section>
    <section className="pu-panel" aria-labelledby="fc-h">
      <h2 className="pu-title" id="fc-h">Forecast, month by month</h2>
      <div className="im-scroll" tabIndex={0} role="region" aria-label="Forecast, month by month">
        <table className="im-table im-grid" data-testid="model-forecast">
          <thead><tr><th scope="col">Month</th>{m36.map((m) => <th key={m.month} scope="col" className="num">{mon(m.month)}</th>)}</tr></thead>
          <tbody>{lines.map((l, i) => 'section' in l
            ? <tr key={`s${i}`} className="is-sec"><th scope="row" colSpan={m36.length + 1}>{l.section}</th></tr>
            : <tr key={l.label} className={l.strong ? 'is-strong' : undefined}><th scope="row">{l.label}</th>{m36.map((m) => (
              <td key={m.month} className={['num', m.kind === 'F' ? 'is-f' : '', l.est?.(m) ? 'is-est' : '', l.neg?.(m) ? 'is-neg' : ''].filter(Boolean).join(' ')}>
                {l.label.startsWith('A = ') ? <span className={`im-pill ${m.kind === 'A' ? 'is-a' : 'is-proj'}`}>{m.kind}</span> : l.v(m)}</td>))}</tr>)}</tbody>
        </table>
      </div>
      <p className="small muted">Grey figures are forecast. A cost marked est. is the assumption, used where nothing was entered in Admin &gt; Expenses for an actual month. The pro forma tab sums the same months by year, out to 5 years.</p>
    </section></>);
}
