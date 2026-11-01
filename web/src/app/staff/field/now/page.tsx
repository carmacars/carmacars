import { pageMeta } from '@/features/seo/meta';
import { requireStaff, sessionAal } from '@/server/door';
import { BookingsNow } from '@/features/bookings-now/BookingsNow';
import { bookingsNow } from '@/server/bookings-now';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Cars now', path: '/staff/field/now', noindex: true, description: 'Which cars are out, coming back, going out and free.' });

// Field work > Cars now (Release 26, migration 0330): the cars out, coming back and going out and the free ones, read
// only and without the money; the renter's phone only on the field staff member's own jobs (the database decides).
export default async function FieldNow() {
  const { user } = await requireStaff('field', '/staff/field/now');
  const board = await bookingsNow(user.id, { field: true, aal: await sessionAal() }).catch(() => null);
  const at = new Date().getTime();
  return (
    <>
      <header className="fd-home"><h1 className="fd-home__h">Cars now</h1><p className="fd-home__sub">Out, coming back, going out and free. Toronto time.</p></header>
      <BookingsNow initial={board} at={at} src="/api/staff/bookings-now?as=field" base={null} />
    </>
  );
}
