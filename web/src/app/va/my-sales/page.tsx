import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead, Tiles } from '@/features/admin/ui';
import { SalesBoard, type StaffSales } from '@/features/va/SalesBoard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My sales', path: '/va/my-sales', noindex: true, description: 'Your commissions, quotes, offers, bookings and booked revenue.' });

// My sales (migrations 0057 and 0058): the signed-in assistant's own commissions (Sales: the month's rental days against
// the target and the tier), quotes, offers, rentals added, bookings confirmed, conversion and booked revenue by week or
// month, the follow-ups due and each deal. Every staff function.
export default async function MySales({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, fn }, sp] = await Promise.all([vaPage('/va/my-sales'), searchParams]);
  const period = sp.period === 'month' ? 'month' : 'week';
  const [s, fu] = await Promise.all([read<StaffSales>('my_sales', { period }),
    read<{ done: number; open: number; booked: number; chats_handled: number }>('my_followups', { period }).catch(() => null)]);
  return (
    <>
      <PageHead title="My sales" kicker={FN_LABEL[fn]} />
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
