import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: Incidents and claims are tabs of Bookings > Damage and claims (?tab=claims goes to Claims). An incident keeps its own page.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/incidents']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
