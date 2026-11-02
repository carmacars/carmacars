import { redirect } from 'next/navigation';
import { movedTo } from '@/features/portal-nav/tabs';
import { RENTER_MOVED } from '@/features/portal/menu';

// r27 portals: Notifications is the Notifications tab of Account (its query kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab] = RENTER_MOVED['/account/notifications']!;
  redirect(movedTo(to, tab, await searchParams));
}
