import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: Insurer invoices is the Invoices tab of Money > Insurers (a status filter is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/insurer-invoices']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
