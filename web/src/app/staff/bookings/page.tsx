import { pageMeta } from '@/features/seo/meta';
import { BookingsPage } from '@/features/bookings-page/BookingsPage';
import { staffCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings', path: '/staff/bookings', noindex: true, description: 'What is out, coming back and going out now, and find a booking.' });

// Bookings now and Find a booking (0330, 0200). r31: the same page as the Admin's (features/bookings-page).
export default async function FindBooking({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([staffCtx('/staff/bookings'), searchParams]);
  return <BookingsPage ctx={ctx} sp={sp} />;
}
