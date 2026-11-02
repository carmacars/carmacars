import { redirect } from 'next/navigation';
import { movedTo } from '@/features/portal-nav/tabs';
import { RENTER_MOVED } from '@/features/portal/menu';

// The trips are the home (Trips); the query is kept.
export default async function Bookings({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab] = RENTER_MOVED['/account/bookings']!;
  redirect(movedTo(to, tab, await searchParams));
}
