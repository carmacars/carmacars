import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: Owner invoices is the Invoices tab of Money > Owner money (a status filter or search is kept). An invoice keeps its own page.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/invoices']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
