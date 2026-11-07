import { pageMeta } from '@/features/seo/meta';
import { BookingsPage } from '@/features/bookings-page/BookingsPage';
import { adminCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings', path: '/admin/bookings', noindex: true, description: 'What is out, coming back, going out and owed now, and every booking.' });

// Bookings (Release 26, migration 0330). r31: the same page as staff's (features/bookings-page).
export default async function Bookings({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([adminCtx('/admin/bookings'), searchParams]);
  return <BookingsPage ctx={ctx} sp={sp} />;
}
