import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { Tiles } from '@/features/admin/ui';
import { PortalHero } from '@/components/portal-ui/PortalHero';
import { StatCard } from '@/components/portal-ui/StatCard';
import { ProgressRing } from '@/components/portal-ui/ProgressRing';
import { SalesBoard, type StaffSales } from '@/features/va/SalesBoard';
import { pctBps } from '@/features/sales/Commissions';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My sales', path: '/va/my-sales', noindex: true, description: 'Your commissions, quotes, offers, bookings and booked revenue.' });

// My sales (migrations 0057 and 0058; a hero with the month's progress since October 25, 2026): the signed-in assistant's
// own commissions (Sales: the month's rental days against the target and the tier, as a ring with the tiers beside it),
// quotes, offers, rentals added, bookings confirmed, conversion and booked revenue by week or month, the follow-ups due
// and each deal. Every staff function.
export default async function MySales({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, fn }, sp] = await Promise.all([vaPage('/va/my-sales'), searchParams]);
  const period = sp.period === 'month' ? 'month' : 'week';
  const [s, fu] = await Promise.all([read<StaffSales>('my_sales', { period }),
    read<{ done: number; open: number; booked: number; chats_handled: number }>('my_followups', { period }).catch(() => null)]);
  const m = s.commissions.month;
  const tot = s.commissions.totals;
  const now = s.periods[0];
  const tier = m.scheme === 'sales_tier';
  // the tier this month's days reach: the last tier whose start is at or under the days
  const at = tier ? m.tiers.reduce((i, x, k) => (m.days >= x.from_days ? k : i), 0) : -1;
  return (
    <>
      <PortalHero testId="my-sales-hero" titleId="ms-title" kicker={<>{FN_LABEL[fn]} <span aria-hidden="true">/</span> {m.label}</>} title="My sales"
        lead={tier ? `${m.days} of ${m.target_days} rental days this month. You earn ${pctBps(m.rate_bps)} now${m.next ? `: ${m.next.to_go} more days and every rental this month earns ${pctBps(m.next.bps)}.` : ', the top tier.'}`
          : `You earn ${pctBps(m.rate_bps)} of the rental charge of each rental you source.`}
        stats={<>
          <StatCard label="Earned" value={tot.earned} format="cents" testId="ms-earned" sub="pending, approved and paid" />
          <StatCard label="Approved, to be paid" value={tot.approved} format="cents" testId="ms-approved" />
          {now && <StatCard label={`Booked revenue this ${period}`} value={now.revenue_cents} format="cents" testId="ms-revenue" sub={`${now.confirmed} bookings confirmed`} />}
        </>}
        actions={<><Link prefetch={false} className="btn btn--sm btn--primary" href="/va/quotes/new">New quote</Link><Link prefetch={false} className="btn btn--sm btn--ghost" href="/va/bookings/new">Add a rental</Link></>}
        media={tier ? (
          <div className="va-tierbox">
            <ProgressRing value={m.days} max={m.target_days} size={148} stroke={12} accent label={`${m.days}`} sub={`of ${m.target_days} days`} title={`Rental days this month: ${m.days} of ${m.target_days}`} />
            <ol className="va-tiers" aria-label="Commission tiers this month">
              {m.tiers.map((x, i) => {
                const next = m.tiers[i + 1];
                return (
                  <li key={x.from_days} className={i === at ? 'is-on' : i < at ? 'is-past' : undefined} aria-current={i === at ? 'step' : undefined}>
                    <b>{pctBps(x.bps)}</b><span>{i === 0 ? `under ${next?.from_days ?? m.mid_days} days` : `from ${x.from_days} days`}{i === at ? ', your tier now' : ''}</span>
                  </li>);
              })}
            </ol>
          </div>) : undefined} />
      {fu && (
        <section className="pt-card ad-card" aria-labelledby="ms-fu" data-testid="my-followups">
          <div className="pt-card__head"><h2 className="d4" id="ms-fu">Follow-ups and live chat this {period}</h2></div>
          <Tiles items={[{ k: 'Follow-ups done', v: fu.done, sub: 'visitor signals, chat requests and chats left after hours' }, { k: 'Booked after a follow-up', v: fu.booked },
            { k: 'Chats you answered', v: fu.chats_handled }, { k: 'Follow-ups waiting', v: fu.open, href: '/va', warn: fu.open > 0 }]} />
        </section>)}
      <SalesBoard s={s} base="/va/my-sales" sp={sp} own bookingHref={(x) => (x.va_can_open ? `/va/bookings/${encodeURIComponent(x.booking_number)}` : null)} />
    </>
  );
}
