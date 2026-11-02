import Link from '@/components/Link';
import { money } from '@/lib/format';
import { firstOfNextMonth, longDate, monthLabel } from '@/features/deck/returns';
import { HOW_IT_WORKS_AMOUNTS, howItWorksRow } from './calc';
import { FundACar, InvestmentCalculator } from './Sheets';
import { PortalIcon } from '@/components/portal-ui';
import type { InvestorModel } from '@/server/investor-model';

export const TABS = [['mine', 'My investment'], ['calculator', 'Calculator'], ['how', 'How it works'], ['car', 'Fund a car']] as const;
export type Tab = (typeof TABS)[number][0];
const c = (n: number) => money(n, { cents: true });
const STATE: Record<string, [string, string]> = { paid: ['Paid', 'is-paid'], to_be_paid: ['To be paid', 'is-due'], held: ['On hold', 'is-held'], reinvested: ['Reinvested', 'is-paid'], projected: ['Projected', 'is-proj'] };
const multiplierOf = (t: { multiplier: number | string | null }) => { const n = Number(t.multiplier); return Number.isFinite(n) && n > 0 ? n : null; };

// The investor's Live sheets (app/investor/model/page.tsx loads the data; this lays it out): four tabs and the downloads.
export function InvestorModelView({ m, tab, reinvest }: { m: InvestorModel; tab: Tab; reinvest: boolean | undefined }) {
  const { terms, mine } = m;
  const mult = multiplierOf(terms);
  const lock = terms.lockup_months;
  const min = terms.min_cents / 100;
  const q = (extra: Record<string, string>) => { const u = new URLSearchParams({ ...(tab !== 'mine' ? { tab } : {}), ...(reinvest !== undefined ? { reinvest: reinvest ? '1' : '0' } : {}), ...extra }); const s = u.toString(); return s ? `?${s}` : ''; };
  const dl = reinvest !== undefined ? `?reinvest=${reinvest ? 1 : 0}` : '';
  return (
    <div className="im-page stack-lg">
      <header className="im-top">
        <div>
          <p className="pu-eyebrow">Live sheets</p>
          <h1 className="d3">Your investment sheets</h1>
          <p className="muted">Live from your records: when a payment is recorded, this page shows it on your next visit. Download the same sheets any time.</p>
        </div>
        <div className="im-dl">
          <a className="btn btn--primary btn--sm" href={`/investor/model/excel${dl}`} data-testid="model-excel" download><PortalIcon name="download" size={16} />Download as Excel</a>
          <a className="btn btn--ghost btn--sm" href={`/investor/model/pdf${dl}`} data-testid="model-pdf" download><PortalIcon name="download" size={16} />Download as PDF</a>
        </div>
      </header>
      <nav className="pt__subnav im-tabs" aria-label="Sheets">
        {TABS.map(([k, l]) => <Link key={k} prefetch={false} href={`/investor/model${k === 'mine' ? '' : `?tab=${k}`}`} aria-current={tab === k ? 'page' : undefined} data-testid={`model-tab-${k}`}>{l}</Link>)}
      </nav>

      {tab === 'mine' && (mine.rows.length === 0 && mine.investedCents === 0 ? (
        <section className="pu-panel" data-testid="model-mine-empty"><h2 className="pu-title">Your investment appears here once your funds have cleared</h2>
          <p>Until then, try your own numbers on the <Link className="link" href="/investor/model?tab=calculator">Calculator</Link>.</p></section>
      ) : (
        <div className="stack-lg" data-testid="model-mine">
          <div className="im-stats im-stats--6">
            <div className="im-stat im-stat--ink"><span>Invested Amount</span><b data-testid="mine-invested">{c(mine.investedCents)}</b><small>{mine.principalCents !== mine.investedCents ? `${c(mine.principalCents)} paid in` : `${terms.legal_name}`}</small></div>
            <div className="im-stat"><span>Start date</span><b>{mine.startDate ? longDate(mine.startDate) : 'Not set'}</b><small>Investment Date</small></div>
            <div className="im-stat"><span>Yearly Percentage</span><b>{mine.yearlyBps !== null ? `${+(mine.yearlyBps / 100).toFixed(2)}%` : 'Not set'}</b><small>From your agreement</small></div>
            <div className="im-stat"><span>Lockup ends</span><b>{mine.lockupEnd ? longDate(mine.lockupEnd) : 'Not set'}</b><small>{mine.lockupEnd && mine.lockupEnd > terms.today ? 'No return accrues until then' : 'Earning every month'}</small></div>
            <div className="im-stat"><span>Payouts made</span><b data-testid="mine-paid">{c(mine.payoutsMadeCents)}</b><small>{mine.payoutsMadeCount === 1 ? '1 payment' : `${mine.payoutsMadeCount} payments`}{mine.reinvestedCents ? `, ${c(mine.reinvestedCents)} reinvested` : ''}</small></div>
            <div className="im-stat im-stat--accent"><span>{mine.next?.mode === 'reinvest' ? 'Next Return' : 'Next payout'}</span><b data-testid="mine-next">{mine.next ? c(mine.next.cents) : 'Not yet'}</b>
              <small>{mine.next ? `${mine.next.estimated ? 'Estimated, ' : ''}${mine.next.mode === 'reinvest' ? 'added' : 'paid'} ${longDate(mine.next.date)}` : 'After your lockup'}</small></div>
          </div>
          <section className="pu-panel" aria-labelledby="im-sched">
            <div className="im-head">
              <div><h2 className="pu-title" id="im-sched">Your schedule, {mine.rows.length} months</h2>
                <p className="small muted">Your statements as recorded, then the months ahead as your agreement computes them.</p></div>
              <div className="im-toggle" role="group" aria-label="The months ahead">
                <Link prefetch={false} href={`/investor/model${q({ reinvest: '0' })}`} aria-current={!mine.reinvest ? 'true' : undefined} data-testid="mine-paid-toggle">Paid monthly</Link>
                <Link prefetch={false} href={`/investor/model${q({ reinvest: '1' })}`} aria-current={mine.reinvest ? 'true' : undefined} data-testid="mine-reinvest-toggle">Reinvested</Link>
              </div>
            </div>
            {mine.reinvest !== (mine.election === 'reinvest') && <p className="small im-note">Showing your Returns {mine.reinvest ? 'reinvested' : 'paid monthly'} from here on, for comparison. Your current choice is {mine.election === 'reinvest' ? 'reinvested' : 'paid monthly'}; to change it, use <Link className="link" href="/investor/profile">Profile and notices</Link>.</p>}
            <div className="im-scroll" tabIndex={0} role="region" aria-label="Your schedule">
              <table className="im-table im-table--mine" data-testid="mine-schedule">
                <thead><tr><th scope="col">Return Month</th><th scope="col">{mine.reinvest ? 'Paid or added on' : 'Paid on'}</th><th scope="col" className="num">Invested at start</th><th scope="col" className="num">Return</th><th scope="col">Status</th></tr></thead>
                <tbody>{mine.rows.map((x) => {
                  const [lbl, cls] = STATE[x.state] ?? [x.state, ''];
                  return <tr key={x.month} className={x.recorded ? 'is-rec' : undefined}><td>{monthLabel(x.month)}</td><td>{longDate(x.date)}</td><td className="num">{c(x.openingCents)}</td><td className="num">{c(x.returnCents)}</td>
                    <td><span className={`im-pill ${cls}`}>{x.mode === 'reinvest' && x.state === 'projected' ? 'Projected, reinvested' : lbl}</span></td></tr>;
                })}</tbody>
                <tfoot><tr><th scope="row">Months ahead, projected</th><td /><td /><td className="num">{c(mine.reinvest ? mine.projectedReinvestedCents : mine.projectedPaidCents)}</td><td>{mine.reinvest ? 'Reinvested' : 'Paid to you'}</td></tr></tfoot>
              </table>
            </div>
            <p className="small muted">Projected rows use your Invested Amount and Yearly Percentage today. Your monthly statement is the record: see <Link className="link" href="/investor/statements">Statements</Link>.</p>
          </section>
        </div>
      ))}

      {tab === 'calculator' && <InvestmentCalculator amount={m.calc.amount} start={m.calc.start} rate={m.calc.rate} lockupMonths={lock} reinvest={m.calc.reinvest} minimum={min} />}

      {tab === 'how' && (
        <div className="stack-lg" data-testid="model-how">
          {mult && <section className="pu-panel pu-panel--ink im-headline"><p className="im-headline__fig">{mult}x</p><p className="im-headline__what">multiplier on money invested in the fleet</p>
            <p className="xs">The company&apos;s headline figure: internal, not audited, not a forecast and not a promise of any return. Your Return is the Yearly Percentage in your agreement.</p></section>}
          <section className="pu-panel" aria-labelledby="im-terms"><h2 className="pu-title" id="im-terms">The terms in plain words</h2>
            <dl className="im-terms">
              <div><dt>Minimum investment</dt><dd>{money(terms.min_cents)}</dd></div>
              <div><dt>Your return</dt><dd>{+(terms.offer_bps / 100).toFixed(2)}% a year on our current offer, paid monthly. Each investor&apos;s rate is set in their own investment agreement.</dd></div>
              <div><dt>Lockup</dt><dd>The first {lock} months. No return accrues during the lockup. Monthly payments start once it ends.</dd></div>
              <div><dt>Your principal</dt><dd>Stays invested, with no fixed term. Keep it in to keep earning, or reinvest your monthly returns.</dd></div>
              <div><dt>Getting your money out</dt><dd>Sell your investment to another investor, or have it bought back by the company.</dd></div>
              <div><dt>Company repayment</dt><dd>The company can repay your investment at any time with 6 months&apos; notice.</dd></div>
              <div><dt>What it is</dt><dd>An investment, not a loan. Investors receive no shares in the company.</dd></div>
              {terms.company && <div><dt>Who you invest with</dt><dd>{terms.company}</dd></div>}
            </dl>
          </section>
          <section className="pu-panel" aria-labelledby="im-steps"><h2 className="pu-title" id="im-steps">Step by step</h2>
            <ol className="im-steps">
              <li><b>Invest.</b> Sign your investment agreement and fund it (minimum {money(terms.min_cents)}).</li>
              <li><b>Lockup.</b> Months 1 to {lock}: your capital goes to work. No return accrues yet.</li>
              <li><b>Get paid monthly.</b> From month {lock + 1}, you receive your yearly return divided into 12 monthly payments.</li>
              <li><b>Your choice.</b> Keep it in, reinvest your returns, sell to another investor, or have the company buy it back.</li>
            </ol>
          </section>
          <section className="pu-panel" aria-labelledby="im-ex"><h2 className="pu-title" id="im-ex">Examples at {+(terms.offer_bps / 100).toFixed(2)}% a year</h2>
            <div className="im-scroll" tabIndex={0} role="region" aria-label="Examples">
              <table className="im-table" data-testid="how-examples">
                <thead><tr><th scope="col">Amount invested</th><th scope="col" className="num">Monthly payout</th><th scope="col" className="num">Yearly payout</th><th scope="col" className="num">Paid by month 24</th><th scope="col" className="num">Paid by month 36</th></tr></thead>
                <tbody>{HOW_IT_WORKS_AMOUNTS.map((a) => { const x = howItWorksRow(a, terms.offer_bps / 10000, lock); return <tr key={a}><td>{money(a * 100)}</td><td className="num">{money(Math.round(x.monthly * 100))}</td><td className="num">{money(Math.round(x.yearly * 100))}</td><td className="num">{money(Math.round(x.by24 * 100))}</td><td className="num">{money(Math.round(x.by36 * 100))}</td></tr>; })}</tbody>
              </table>
            </div>
            <p className="small muted">Returns paid out, not reinvested. For informational purposes only and not an offer by itself; the signed investment agreement governs. Like any investment, it carries risk.</p>
          </section>
        </div>
      )}

      {tab === 'car' && <FundACar firstMonth={firstOfNextMonth(terms.today)} />}

      <p className="small muted">This page shows your own records and the investment terms. It is not an offer or a solicitation.</p>
    </div>
  );
}
