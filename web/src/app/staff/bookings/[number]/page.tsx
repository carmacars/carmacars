import { pageMeta } from '@/features/seo/meta';
import { BookingPage } from '@/features/booking-page/BookingPage';
import { staffCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Booking', path: '/staff', noindex: true, description: 'One booking, as the assistant works it.' });

// One booking for an assistant (05-va.md sections 2 to 5). r31: the same page as the Admin's (features/booking-page),
// read through the staff door in the page's function; sections and buttons show by the function (shared-pages/viewer).
export default async function VaBooking({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ number }, sp] = await Promise.all([params, searchParams]);
  const n = decodeURIComponent(number);
  return <BookingPage ctx={await staffCtx(`/staff/bookings/${n}`)} number={n} sp={sp} />;
}
