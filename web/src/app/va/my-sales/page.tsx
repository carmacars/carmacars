import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { SalesBoard, type StaffSales } from '@/features/va/SalesBoard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My sales', path: '/va/my-sales', noindex: true, description: 'Your quotes, offers, bookings and booked revenue.' });

// My sales (migration 0057): the signed-in Sales assistant's own quotes, offers, rentals added, bookings confirmed,
// conversion and booked revenue by week or month, the follow-ups due and each deal. Tracking only, no commission.
export default async function MySales({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, fn }, sp] = await Promise.all([vaPage('/va/my-sales', ['sales']), searchParams]);
  const s = await read<StaffSales>('my_sales', { period: sp.period === 'month' ? 'month' : 'week' });
  return (
    <>
      <PageHead title="My sales" kicker={FN_LABEL[fn]} />
      <SalesBoard s={s} base="/va/my-sales" sp={sp} own bookingHref={(x) => (x.va_can_open ? `/va/bookings/${encodeURIComponent(x.booking_number)}` : null)} />
    </>
  );
}
