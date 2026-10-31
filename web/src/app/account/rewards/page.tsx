import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { rpc } from '@/lib/db/repo';
import { requireUser } from '@/server/portal/data';
import { money, pct } from '@/lib/format';
import type { RewardsState } from '@/features/rewards/types';
import { CancelCode, CopyLink, GoogleClaim, Redeem } from '@/features/rewards/RewardsClient';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Rewards', path: '/account/rewards', noindex: true, description: 'Your CarmaCars Rewards points, tier and codes.' });

const fmtDate = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(new Date(d));
const fmtAt = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'America/Toronto' }).format(new Date(d));

// The renter's CarmaCars Rewards (migration 0214): points and what they are worth, the tier and its code, ways to earn
// (referral link, follows, reviews), codes made from points, and every change with its reason.
export default async function Rewards() {
  const user = await requireUser('/account/rewards');
  const r = (await rpc('my_rewards', {}, { role: 'authenticated', userId: user.id })) as unknown as RewardsState;
  if (!r.enabled || !r.renter) {
    return <><PageHeader title="Rewards" purpose="Points on every rental." /><section className="pt-card"><p>{r.enabled ? 'Rewards start with your first booking request.' : 'Rewards are paused right now.'}</p></section></>;
  }
  return (
    <>
      <PageHeader title="Rewards" purpose="Points on every rental, off your next rental charge." testId="rewards-head" />
      <div className="pt-split">
        <div className="stack">
          <section className="pt-card" aria-labelledby="rw-bal" data-testid="rewards-balance">
            <h2 className="d4" id="rw-bal">{r.balance.toLocaleString('en-CA')} points</h2>
            <p>Worth <b>{money(r.value_cents, { cents: true })}</b> off the rental charge. {r.expires_on ? `They end on ${fmtDate(r.expires_on)} unless you rent or redeem before then.` : ''}</p>
            <p className="small"><b>{r.tier.name}</b>{r.tier.discount_bps > 0 ? `: ${pct(r.tier.discount_bps)} off the rental charge with your code ${r.tier.promo_code ?? ''}` : ''}. {r.tier.perk ?? ''}</p>
            {r.next_tier && <p className="small muted">{r.rental_days_12m} rental days in the last 12 months. {r.next_tier.days_needed} more for {r.next_tier.name}{r.next_tier.discount_bps ? ` (${pct(r.next_tier.discount_bps)} off)` : ''}.</p>}
          </section>
          <section className="pt-card" aria-labelledby="rw-use">
            <h2 className="d4" id="rw-use">Use your points</h2>
            <Redeem balance={r.balance} min={r.min_redeem} centsPerPoint={r.point_value_cents} validDays={r.code_valid_days} />
            {r.codes.length > 0 && <ul className="linklist" data-testid="rewards-codes">{r.codes.map((c) => (
              <li key={c.id} className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'center' }}>
                <span><b>{c.code}</b>: {money(c.amount_cents, { cents: true })} off, {c.used ? 'used' : c.in_use ? 'on a booking' : `until ${fmtDate(c.valid_until)}`}</span>
                {!c.in_use && <CancelCode code={c.code} />}
              </li>))}</ul>}
          </section>
          <section className="pt-card" aria-labelledby="rw-earn" data-testid="rewards-earn">
            <h2 className="d4" id="rw-earn">Ways to earn</h2>
            <ul className="linklist">{r.actions.map((a) => (
              <li key={a.code}><b>{a.label}</b>: {a.code === 'rental' ? `${a.points} point${a.points === 1 ? '' : 's'} a dollar` : `${a.points} points`} <span className="small muted">({a.limit})</span>{a.detail && <span className="small muted"> {a.detail}</span>}</li>))}</ul>
            <h3 className="d4">Refer a friend</h3>
            <p className="small">Share your link. When a friend books with it and completes their first rental, you both get points.</p>
            <p className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'center' }}><code data-testid="rewards-referral" style={{ overflowWrap: 'anywhere' }}>{r.referral_url}</code><CopyLink url={r.referral_url} /></p>
            {r.socials.length > 0 && <>
              <h3 className="d4">Follow us</h3>
              <p className="small muted">The points come when you open our page from here. We cannot see who follows, so this is on your word.</p>
              <ul className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', listStyle: 'none', padding: 0 }}>{r.socials.map((s) => (
                <li key={s.platform}><a className="btn btn--ghost btn--sm" href={`/account/rewards/follow/${s.platform}`} target="_blank" rel="noopener" data-testid={`rewards-follow-${s.platform}`}>{s.label.replace('Follow us on ', '')}{s.done ? ' (points added)' : `: ${s.points} points`}</a></li>))}</ul>
            </>}
            {r.site_reviews.length > 0 && <>
              <h3 className="d4">Review your rental on carmacars.ca</h3>
              <ul className="linklist">{r.site_reviews.map((b) => (
                <li key={b.number}>{b.vehicle} ({b.number}): {b.reviewed ? 'reviewed, thank you' : <Link prefetch={false} className="link" href={`/account/bookings/${b.number}/review`}>Write a review</Link>}</li>))}</ul>
            </>}
            {r.google && r.google.bookings.length > 0 && <div data-testid="rewards-google">
              <h3 className="d4">Review us on Google</h3>
              <p className="small">{r.google.points} points for each rental, for any honest review, good or bad. Post it, then come back and press I posted my review.</p>
              <p><a className="btn btn--ghost btn--sm" href={r.google.url} target="_blank" rel="noopener">Open Google reviews</a></p>
              <ul className="linklist">{r.google.bookings.map((b) => (
                <li key={b.number} className="stack"><span>{b.vehicle} ({b.number})</span>{b.claimed ? <span className="small muted">Points added</span> : <GoogleClaim number={b.number} />}</li>))}</ul>
            </div>}
          </section>
        </div>
        <aside className="pt-split__aside">
          <section className="pt-card" aria-labelledby="rw-tiers">
            <h2 className="d4" id="rw-tiers">Tiers</h2>
            <ul className="linklist">{r.tiers.map((t) => <li key={t.code}><b>{t.name}</b>{t.min_days ? `, from ${t.min_days} rental days in 12 months` : ''}{t.perk ? `: ${t.perk}` : ''}</li>)}</ul>
          </section>
          <section className="pt-card" aria-labelledby="rw-hist" data-testid="rewards-history">
            <h2 className="d4" id="rw-hist">History</h2>
            {r.ledger.length ? <ul className="linklist">{r.ledger.map((l, i) => (
              <li key={i}><span className="num"><b>{l.points > 0 ? '+' : ''}{l.points.toLocaleString('en-CA')}</b></span> {l.reason}{l.reversed ? ' (reversed)' : ''} <span className="xs muted">{fmtAt(l.at)}</span></li>))}</ul>
              : <p className="small muted">Nothing yet. Your first rental earns points when it closes.</p>}
          </section>
        </aside>
      </div>
    </>
  );
}
