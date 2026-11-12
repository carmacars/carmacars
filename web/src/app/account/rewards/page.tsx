import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { rpc } from '@/lib/db/repo';
import { requireUser } from '@/server/portal/data';
import { money } from '@/lib/format';
import { ladderView, tierRank, type RewardsState, type TierPerk } from '@/features/rewards/types';
import { CancelCode, CopyLink, GoogleClaim, PerkHint, Redeem, TierUpOnce } from '@/features/rewards/RewardsClient';
import { Timeline, TimelineItem } from '@/components/portal-ui';
import { MyDiscounts } from '@/features/rewards/MyDiscounts';
import type { SavedDiscount } from '@/features/rewards/discounts';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Rewards', path: '/account/rewards', noindex: true, description: 'Your CarmaCars Rewards points, tier and codes.' });

const fmtDate = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(new Date(d));
const fmtAt = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'America/Toronto' }).format(new Date(d));

// The renter's CarmaCars Rewards (migration 0214): points and what they are worth, the tier and its code, ways to earn
// (referral link, follows, reviews), codes made from points, and every change with its reason.
// r40 (2421): first the tier: where the renter is on Gold, Platinum and Black (points earned in 12 months), the points to
// the next one on the checklist bar, the perks they have; then the ladder with each tier's perks (the portals' timeline).

/** How to use a perk, in one line. */
const HOW: Record<TierPerk['code'], (hours: number) => string> = {
  instant_book: () => 'Send a request as usual: it is booked at once, then you sign and pay.',
  any_car: (h) => `On a car's page, pick your dates even when they show as taken, and send the request. We answer within ${h} ${h === 1 ? 'hour' : 'hours'}.`,
  free_day: () => 'Your code is below. Type it in the promo code box of your next request.'
};
export default async function Rewards() {
  const user = await requireUser('/account/rewards');
  const [r, discounts] = await Promise.all([rpc('my_rewards', {}, { role: 'authenticated', userId: user.id }).then((x) => x as unknown as RewardsState),
    // r40 (2423): every discount code the renter holds
    rpc('server_my_discounts' as never, { p_user: user.id } as never, { role: 'service_role' }).then((x) => x as unknown as SavedDiscount[]).catch(() => [] as SavedDiscount[])]);
  if (!r.enabled || !r.renter) {
    return <><PageHeader title="Rewards" purpose="Points on every rental." /><section className="pt-card"><p>{r.enabled ? 'Rewards start with your first booking request.' : 'Rewards are paused right now.'}</p></section></>;
  }
  const l = r.ladder ?? null;
  const lv = l ? ladderView(l) : null;
  return (
    <>
      <PageHeader title="Rewards" purpose="Points on every rental, off your next rental charge. Earn more to reach Gold, Platinum and Black." testId="rewards-head" />
      <div className="pt-split">
        <div className="stack">
          {lv && l && (
            <section className="pt-card stack" aria-labelledby="rw-tier" data-testid="rewards-tier" data-tier={l.tier_code ?? 'member'}>
              <TierUpOnce rank={tierRank(l)} name={lv.current?.name ?? 'Member'} />
              <PerkHint anyCar={lv.perks.some((k) => k.code === 'any_car')} hours={l.any_car_hours} />
              <p className="pu-eyebrow">Your tier</p>
              <h2 className="d3" id="rw-tier">{lv.current?.name ?? 'Member'}</h2>
              <p className="small">{l.points_12m.toLocaleString('en-CA')} points earned in the last 12 months. Using points never lowers your tier.</p>
              <div className="ck-progress" data-testid="rewards-tier-progress" data-complete={!lv.next || undefined}>
                <div className="ck-progress__bar" role="progressbar" aria-label="Progress to the next tier" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(lv.progress * 100)} aria-valuetext={lv.line}>
                  <span className="ck-progress__fill" style={{ ['--p' as string]: String(lv.progress) }} />
                </div>
                <p className="ck-progress__text small" data-testid="rewards-tier-line">{lv.line}</p>
              </div>
              {lv.perks.length > 0
                ? <ul className="pt-steps" aria-label="Your perks" data-testid="rewards-perks">{lv.perks.map((k) => <li key={k.code} className="is-done"><span><b>{k.label}</b><small>{HOW[k.code]?.(l.any_car_hours) ?? k.detail}</small></span></li>)}</ul>
                : <p className="small muted">Earn points on every rental, review and referral. At {lv.next?.min_points.toLocaleString('en-CA')} points you reach {lv.next?.name} and get {lv.next?.perks.map((k) => k.label).join(' and ') || 'its perks'}.</p>}
              {l.free_day && <p className="alert alert--ok" data-testid="rewards-free-day"><span className="alert__title">Your free rental day: {l.free_day.code}</span>
                <span>{l.free_day.used ? 'Used, thank you. Your next one comes a year after this one.' : `One free day on your next rental${l.free_day.valid_until ? `, until ${fmtAt(l.free_day.valid_until)}` : ''}. Type the code in the promo code box when you send a request.`}</span></p>}
            </section>
          )}
          <section className="pt-card" aria-labelledby="rw-bal" data-testid="rewards-balance">
            <h2 className="d4" id="rw-bal">{r.balance.toLocaleString('en-CA')} points</h2>
            <p>Worth <b>{money(r.value_cents, { cents: true })}</b> off the rental charge. {r.expires_on ? `They end on ${fmtDate(r.expires_on)} unless you rent or redeem before then.` : ''}</p>
            {r.tier.promo_code && <p className="small">Your earlier tier code {r.tier.promo_code} still works until it ends.</p>}
          </section>
          <MyDiscounts list={discounts} />
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
          {lv && l && (
            <section className="pt-card" aria-labelledby="rw-tiers" data-testid="rewards-ladder">
              <h2 className="d4" id="rw-tiers">Tiers</h2>
              <p className="small muted">By points earned in the last 12 months. Each tier keeps the perks of the ones before it.</p>
              <Timeline label="Rewards tiers">{lv.states.map(({ tier, state }) => (
                <TimelineItem key={tier.code} testId={`rewards-ladder-${tier.code}`} state={state === 'done' ? 'done' : state === 'now' ? 'now' : 'future'}
                  title={<>{tier.name}{tier.code === l.tier_code ? ' (your tier)' : ''}</>} amount={`${tier.min_points.toLocaleString('en-CA')} points`}
                  meta={<>{tier.perks.map((k) => <span key={k.code}>{k.label}{k.detail ? `: ${k.detail}` : ''}</span>)}</>} />))}
              </Timeline>
            </section>
          )}
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
