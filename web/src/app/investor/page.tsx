import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { door, requireInvestor } from '@/server/door';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { signCount } from '@/features/manual/SignPages';
import { Attention, More, type AttentionItem } from '@/features/portal/Chrome';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your investments', path: '/investor', noindex: true, description: 'Your investments and statements.' });

type Home = { investor: { legal_name: string; status: string; tax_information_complete: boolean }; agreement: { agreement_number: string } | null;
  investments: Array<{ id: string; principal_cents: number; reinvested_cents: number; redeemed_cents: number; invested_amount_cents: number; yearly_bps: number; investment_date: string; lockup_end_date: string; status: string; mode: string; next_payment_date: string }>;
  latest: { id: string; return_month: string; return_cents: number; disposition: string; status: string } | null;
  redemptions: Array<{ notice_date: string; redemption_date: string; amount_cents: number; status: string }>; held: Array<{ return_month: string; return_cents: number; hold_reason: string | null }>;
  requests: Array<{ title: string; status: string; created_at: string }> };
const c = (n: number) => money(n, { cents: true });
const day = (s: string) => when(`${s}T12:00:00Z`, false);
const month = (s: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${s}T12:00:00Z`));

// Home (07-investor.md section 2): one card per investment, the latest statement, notices from CarmaCars.
export default async function InvestorHome() {
  const { user } = await requireInvestor('/investor');
  const [h, deck, toSign] = await Promise.all([door<Home>(user.id, 'investor_read', 'home'),
    door<{ visible: boolean }>(user.id, 'investor_read', 'deck_visible').then((r) => r.visible).catch(() => false), signCount(user.id)]);
  const today = new Date().toISOString().slice(0, 10);
  // what needs the investor first (portal cleanup, October 23, 2026), then the numbers
  const attention: AttentionItem[] = [
    ...(toSign ? [{ key: 'sign', title: toSign === 1 ? 'A document to sign' : `${toSign} documents to sign`, href: '/investor/sign', cta: 'Read and sign', testId: 'investor-to-sign' }] : []),
    ...h.redemptions.map((r, i) => ({ key: `r${i}`, title: `Redemption notice: ${c(r.amount_cents)} on ${day(r.redemption_date)}`, note: `Notice of ${day(r.notice_date)}.`, href: '/investor/profile', cta: 'Your notices' })),
    ...h.held.map((r, i) => ({ key: `h${i}`, title: `Return on hold: ${month(r.return_month)}, ${c(r.return_cents)}`, note: r.hold_reason ?? undefined, href: '/investor/statements', cta: 'Statements' }))
  ];
  return (
    <div className="stack">
      <header><p className="pt-kicker">{h.agreement ? `Agreement ${h.agreement.agreement_number}` : 'Investor'}</p><h1 className="d2" data-testid="investor-name">{h.investor.legal_name}</h1></header>
      <Attention items={attention} />
      {h.investments.map((x) => (
        <section key={x.id} className="pt-card" data-testid="investment" aria-labelledby={`iv-${x.id}`}>
          <h2 className="d4" id={`iv-${x.id}`}>Invested Amount <span data-testid="invested-amount">{c(x.invested_amount_cents)}</span></h2>
          <dl className="pt-dl">
            <div><dt>Yearly Percentage</dt><dd>{(x.yearly_bps / 100).toFixed(2)}%</dd></div>
            <div><dt>Returns</dt><dd>{x.mode === 'reinvest' ? 'Reinvested' : 'Paid monthly'}</dd></div>
            <div><dt>Next Payment Date</dt><dd>{day(x.next_payment_date)}</dd></div>
          </dl>
          <More summary="Principal, dates and amounts to date">
            <dl className="pt-dl">
              <div><dt>Principal</dt><dd>{c(x.principal_cents)}</dd></div><div><dt>Reinvested to date</dt><dd>{c(x.reinvested_cents)}</dd></div>
              <div><dt>Redeemed to date</dt><dd>{c(x.redeemed_cents)}</dd></div>
              <div><dt>Investment Date</dt><dd>{day(x.investment_date)}</dd></div>
              <div><dt>Lockup End Date</dt><dd>{day(x.lockup_end_date)}{x.lockup_end_date > today ? '. No return is earned for the lockup period.' : ''}</dd></div>
            </dl>
          </More>
        </section>
      ))}
      <section className="pt-card" aria-labelledby="ls-t"><h2 className="d4" id="ls-t">Latest statement</h2>
        {h.latest ? <p>{month(h.latest.return_month)}: {c(h.latest.return_cents)}, {h.latest.disposition === 'reinvest' ? 'reinvested' : 'paid'} ({h.latest.status.replace(/_/g, ' ')}). <Link className="link" href={`/investor/statements/${h.latest.id}`}>Open</Link></p>
          : <p className="small">Your first Return Month starts on {h.investments[0] ? day(h.investments[0].lockup_end_date) : 'the Lockup End Date'}. Statements will appear here.</p>}
      </section>
      {deck && <section className="pt-card" data-testid="deck-promo" aria-labelledby="dk-t">
        <h2 className="d4" id="dk-t">The CarmaCars investor deck</h2>
        <p className="small">What we built, how CarmaCars makes money, how your Return builds month by month, and a calculator for your own numbers.</p>
        <p><Link href="/investor/deck" prefetch={false} className="btn btn--ghost btn--sm">Open the deck</Link></p>
      </section>}
      {h.requests.length > 0 && <section className="pt-card" aria-labelledby="rq-t"><h2 className="d4" id="rq-t">Your notices</h2><ul className="small">{h.requests.map((r, i) => <li key={i}>{when(r.created_at)}: {r.title} ({r.status === 'done' ? 'recorded' : 'received'})</li>)}</ul></section>}
      <p className="small muted">This area shows your records under your Investment Agreement. It is not an offer or a solicitation.</p>
    </div>
  );
}
