import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: Renter leads is the Leads tab of People > Renters (a search or filter is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/leads']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
