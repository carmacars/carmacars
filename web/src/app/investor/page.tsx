import Link from 'next/link';
import { InfoTip } from '@/components/InfoTip';
import { pageMeta } from '@/features/seo/meta';
import { door, requireInvestor } from '@/server/door';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { signCount } from '@/features/manual/SignPages';
import { More } from '@/features/portal/Chrome';
import type { DeckFigures } from '@/features/deck/types';
import { investorPlan, type InvestorHome, type ReturnRow } from '@/features/investor/plan';
import { ActionTiles, DocumentList, DocumentRow, LineChart, PortalHero, ProgressRing, PuIcon, StatCard, Timeline, TimelineItem, type ActionTileItem } from '@/components/portal-ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your investments', path: '/investor', noindex: true, description: 'Your investments and statements.' });

const c = (n: number) => money(n, { cents: true });
const day = (s: string) => when(`${s}T12:00:00Z`, false);
const month = (s: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${s.slice(0, 10)}T12:00:00Z`));
const torontoToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

// Home (07-investor.md section 2): what needs the investor, then their own money: invested, paid, next payment, the
// schedule and the growth of their account, from their own records only (investor_read home and statements). Nothing about
// the fleet (its size, use, insurance or costs) is read here.
export default async function InvestorHome() {
  const { user } = await requireInvestor('/investor');
  const [h, rows, deck, toSign] = await Promise.all([door<InvestorHome>(user.id, 'investor_read', 'home'), door<ReturnRow[]>(user.id, 'investor_read', 'statements').catch(() => [] as ReturnRow[]),
    door<{ visible: boolean }>(user.id, 'investor_read', 'deck_visible').then((r) => r.visible).catch(() => false), signCount(user.id)]);
  const today = torontoToday();
  // the deck's headline figures, as the Admin set them (deck_settings); only these two are shown here
  const headline = deck ? await door<DeckFigures>(user.id, 'investor_read', 'deck').then((f) => ({ multiplier: Number(f.settings.deck_multiplier), bps: f.settings.deck_return_bps })).catch(() => null) : null;
  const plan = investorPlan(h, rows, today);
  // what needs the investor first (portal cleanup, October 23, 2026), then the numbers
  const attention: ActionTileItem[] = [
    ...(toSign ? [{ key: 'sign', title: toSign === 1 ? 'A document to sign' : `${toSign} documents to sign`, note: 'Read it and sign on this screen.', href: '/investor/sign', cta: 'Read and sign', testId: 'investor-to-sign', icon: 'sign' as const, urgent: true }] : []),
    ...h.redemptions.map((r, i) => ({ key: `r${i}`, title: `Redemption notice: ${c(r.amount_cents)} on ${day(r.redemption_date)}`, note: `Notice of ${day(r.notice_date)}.`, href: '/investor/profile', cta: 'Your notices', icon: 'doc' as const })),
    ...h.held.map((r, i) => ({ key: `h${i}`, title: `Return on hold: ${month(r.return_month)}, ${c(r.return_cents)}`, note: r.hold_reason ?? undefined, href: '/investor/statements', cta: 'Statements', icon: 'alert' as const }))
  ];
  const reinvesting = h.investments.length > 0 && h.investments.every((x) => x.mode === 'reinvest');
  return (
    <div className="stack-lg iv-home">
      <PortalHero testId="investor-hero" titleId="investor-name-h" kicker={h.agreement ? `Agreement ${h.agreement.agreement_number}` : 'Investor'}
        title={<span data-testid="investor-name">{h.investor.legal_name}</span>}
        lead={h.investments.length ? `${reinvesting ? 'Your Returns are reinvested each month.' : 'Your Returns are paid monthly.'} Every figure here is from your own statements.` : 'Your investment appears here once your agreement is signed and your funds have cleared.'}
        stats={h.investments.length ? <>
          <StatCard label="Invested Amount" value={plan.investedCents} format="cents" size="lg" testId="investor-total-invested" />
          <StatCard label={reinvesting ? 'Reinvested to date' : 'Returns paid to date'} value={reinvesting ? plan.reinvestedCents : plan.paidCents} format="cents" testId="investor-paid-to-date"
            sub={plan.earnedCents > 0 ? `${c(plan.earnedCents)} earned in all` : 'Your first Return Month follows the lockup'} />
          <StatCard label={reinvesting ? 'Next Return' : 'Next payment'} value={plan.next ? plan.next.cents : 'Not set yet'} format="cents" testId="investor-next-payment"
            sub={plan.next ? `${plan.next.estimated ? 'Estimated, ' : ''}${reinvesting ? 'added on' : 'paid on'} ${day(plan.next.date)}` : undefined} />
        </> : undefined}
        media={plan.chart.labels.length > 1 ? (
          <div className="iv-hero-chart pu-on-ink">
            <p className="pu-eyebrow">Your account, month by month</p>
            <LineChart testId="investor-growth" title="Your Invested Amount and Returns to date, by month" labels={plan.chart.labels} fmt={(v) => money(Math.round(v / 100) * 100)}
              series={[
                { key: 'inv', label: 'Invested Amount', values: plan.chart.invested, tone: 'ink' },
                { key: 'ret', label: 'Returns to date', values: plan.chart.returns, tone: 'accent', fill: true },
                { key: 'proj', label: 'Returns, projected', values: plan.chart.projected, tone: 'dash' }
              ]} />
          </div>) : undefined} />
      <ActionTiles items={attention} />
      <div className="pu-grid-2 pu-grid-2--wide">
        <div className="stack-lg">
          {h.investments.map((x) => {
            const locked = x.lockup_end_date > today;
            const total = Math.max(1, (Date.parse(x.lockup_end_date) - Date.parse(x.investment_date)) / 86_400_000);
            const gone = Math.max(0, Math.min(total, (Date.parse(today) - Date.parse(x.investment_date)) / 86_400_000));
            return (
              <section key={x.id} className="pu-panel iv-inv" data-testid="investment" aria-labelledby={`iv-${x.id}`}>
                <div className="iv-inv__head">
                  <div><p className="pu-eyebrow">{x.is_initial === false ? 'Additional investment' : 'Investment'} since {day(x.investment_date)}</p>
                    <h2 className="d4" id={`iv-${x.id}`}>Invested Amount <span className="iv-inv__amount" data-testid="invested-amount">{c(x.invested_amount_cents)}</span></h2></div>
                  {locked ? <ProgressRing value={gone} max={total} title={`Lockup period: ${Math.round((gone / total) * 100)}% done, ends ${day(x.lockup_end_date)}`} label={`${Math.round((gone / total) * 100)}%`} sub="lockup" accent />
                    : <ProgressRing value={1} max={1} title="Earning a Return each month" label={<PuIcon name="check" />} sub="earning" />}
                </div>
                <dl className="pt-dl">
                  <div><dt>Yearly Percentage<InfoTip k="yearly_percentage" topic="the Yearly Percentage" /></dt><dd>{(x.yearly_bps / 100).toFixed(2)}%</dd></div>
                  <div><dt>Returns<InfoTip k="returns_mode" topic="how returns are handled" /></dt><dd>{x.mode === 'reinvest' ? 'Reinvested' : 'Paid monthly'}</dd></div>
                  <div><dt>Next Payment Date</dt><dd>{day(x.next_payment_date)}</dd></div>
                </dl>
                <More summary="Principal, dates and amounts to date">
                  <dl className="pt-dl">
                    <div><dt>Principal</dt><dd>{c(x.principal_cents)}</dd></div><div><dt>Reinvested to date</dt><dd>{c(x.reinvested_cents)}</dd></div>
                    <div><dt>Redeemed to date</dt><dd>{c(x.redeemed_cents)}</dd></div>
                    <div><dt>Investment Date</dt><dd>{day(x.investment_date)}</dd></div>
                    <div><dt>Lockup End Date<InfoTip k="lockup_end" topic="the lockup" /></dt><dd>{day(x.lockup_end_date)}{locked ? '. No return is earned for the lockup period.' : ''}</dd></div>
                  </dl>
                </More>
              </section>
            );
          })}
          <section className="stack" aria-labelledby="ls-t"><h2 className="pt-section-title" id="ls-t">Latest statement</h2>
            {h.latest ? <DocumentList testId="investor-latest" label="Latest statement">
                <DocumentRow href={`/investor/statements/${h.latest.id}`} badge="ST" title={`Statement for ${month(h.latest.return_month)}`}
                  meta={<span>{h.latest.status === 'paid' ? 'Paid' : h.latest.status === 'reinvested' || h.latest.disposition === 'reinvest' ? 'Reinvested' : h.latest.status === 'held' ? 'On hold' : 'To be paid'}</span>}
                  amount={c(h.latest.return_cents)} action={<Link className="link small" href={`/investor/statements/${h.latest.id}`}>Open</Link>} />
              </DocumentList>
              : <p className="small">Your first Return Month starts on {h.investments[0] ? day(h.investments[0].lockup_end_date) : 'the Lockup End Date'}. Statements will appear here.</p>}
            {h.latest && <p className="small"><Link className="link" href="/investor/statements">Every statement and the yearly downloads</Link></p>}
          </section>
        </div>
        <div className="stack-lg">
          {plan.schedule.length > 0 && (
            <section className="pu-panel" aria-labelledby="iv-sched" data-testid="investor-schedule">
              <div className="pu-panel__head"><h2 className="pu-title" id="iv-sched">{reinvesting ? 'Return schedule' : 'Payment schedule'}</h2></div>
              <Timeline label={reinvesting ? 'Return schedule' : 'Payment schedule'}>
                {plan.schedule.map((s) => (
                  <TimelineItem key={s.key} date={s.date} dateLabel={day(s.date)} state={s.state} title={s.title} amount={c(s.cents)}
                    meta={<><span>{s.note}</span>{s.estimated && <span>Estimated</span>}</>} />
                ))}
              </Timeline>
              <p className="pu-chart__cap">Estimated amounts use your Invested Amount and Yearly Percentage today, as your agreement computes a Return; your statement for each month is the record.</p>
            </section>
          )}
          {deck && <section className="pu-panel pu-panel--ink iv-deck" data-testid="deck-promo" aria-labelledby="dk-t">
            <p className="pu-eyebrow">For investors</p>
            <h2 className="d3" id="dk-t">The CarmaCars investor deck</h2>
            {headline && <div className="iv-deck__figs pu-on-ink">
              {headline.multiplier > 0 && <StatCard label="Our multiplier on money invested in the fleet" value={headline.multiplier} format="x" testId="deck-tile-multiplier" />}
              {headline.bps > 0 && <StatCard label="Our current offer, a year" value={headline.bps / 100} format="pct1" />}
            </div>}
            {headline && headline.multiplier > 0 && <p className="xs muted">The multiplier is CarmaCars&apos; own internal figure, not audited, not a forecast and not a promise of any return. Your Return is the Yearly Percentage in your agreement.</p>}
            <p className="small muted">What we built, how CarmaCars makes money, how your Return builds month by month, and a calculator for your own numbers.</p>
            <p><Link href="/investor/deck" prefetch={false} className="btn btn--primary btn--sm iv-deck__cta"><PuIcon name="play" />Open the deck</Link></p>
          </section>}
          {h.requests.length > 0 && <section className="pu-panel" aria-labelledby="rq-t"><h2 className="pu-title" id="rq-t">Your notices</h2><ul className="small">{h.requests.map((r, i) => <li key={i}>{when(r.created_at)}: {r.title} ({r.status === 'done' ? 'recorded' : 'received'})</li>)}</ul></section>}
        </div>
      </div>
      <p className="small muted">This area shows your records under your Investment Agreement. It is not an offer or a solicitation.</p>
    </div>
  );
}
