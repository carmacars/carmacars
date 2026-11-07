import { pageMeta } from '@/features/seo/meta';
import { BookingPage } from '@/features/booking-page/BookingPage';
import { adminCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Booking', path: '/admin/bookings', noindex: true, description: 'One booking: review, money, history.' });

// One booking for every status (03-admin.md section 4). r31: the same page as staff's (features/booking-page), read
// through the Admin's door.
export default async function Booking({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ number }, sp] = await Promise.all([params, searchParams]);
  const n = decodeURIComponent(number);
  return <BookingPage ctx={await adminCtx(`/admin/bookings/${n}`)} number={n} sp={sp} />;
}
